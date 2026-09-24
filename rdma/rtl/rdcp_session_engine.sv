`timescale 1ps / 1ps

module rdcp_session_engine (
  input  logic         clk,
  input  logic         reset,

  input  logic         request_valid,
  output logic         request_ready,
  input  rdcp_pkg::rdcp_request_descriptor_t request,
  output logic         transaction_active,

  output logic         response_valid,
  input  logic         response_ready,
  output rdcp_pkg::rdcp_response_descriptor_t response_descriptor,
  output logic         replay_valid,
  input  logic         replay_ready,
  output logic         cache_invalidate,
  input  logic         cache_valid,
  input  logic [31:0]  cache_transaction_id,
  input  logic [7:0]   cache_opcode,
  input  logic         response_done,

  output logic         cfg_valid,
  input  logic         cfg_ready,
  output logic [47:0]  cfg_remote_mac,
  output logic [31:0]  cfg_remote_ip,
  output logic [23:0]  cfg_remote_qpn,
  output logic [23:0]  cfg_local_psn,
  output logic [47:0]  cfg_remote_base,
  output logic [31:0]  cfg_rkey,
  output logic [31:0]  cfg_ring_size,
  output logic [31:0]  cfg_wr_size,
  output logic [31:0]  cfg_notify_interval_bytes,
  output logic [63:0]  cfg_local_base,
  output logic [47:0]  cfg_commit_remote_addr,
  output logic         cfg_enable_immediate,
  input  logic         cfg_done,
  input  logic         cfg_accepted,
  input  logic [31:0]  cfg_reject_reason,
  output logic         start_request,
  output logic         stop_request,
  output logic         command_abort_request,

  input  rdcp_pkg::rdcp_endpoint_status_t endpoint_status,
  output logic         fault_abort_request,
  output logic [63:0]  consumed_bytes,
  output logic [3:0]   session_state,
  output logic         safe_to_release,
  output logic [31:0]  config_generation
);
  import rdcp_pkg::*;

  typedef enum logic [3:0] {
    ENGINE_WAIT_REQUEST,
    ENGINE_DISPATCH,
    ENGINE_CONFIG_CAPTURE,
    ENGINE_CONFIG_ADDRESS,
    ENGINE_CONFIG_VALIDATE,
    ENGINE_CONSUME_VALIDATE,
    ENGINE_COMMAND_WAIT,
    ENGINE_FAULT_DRAIN,
    ENGINE_RESPONSE_SUBMIT,
    ENGINE_REPLAY_SUBMIT,
    ENGINE_RESPONSE_WAIT,
    ENGINE_RETIRE_REQUEST
  } engine_state_t;

  typedef enum logic [2:0] {
    ACTION_NONE,
    ACTION_CONFIG,
    ACTION_START,
    ACTION_STOP,
    ACTION_ABORT,
    ACTION_SAFETY_ABORT
  } command_action_t;

  engine_state_t engine_state;
  command_action_t command_action;
  rdcp_request_descriptor_t active_request;

  logic config_session_valid;
  logic config_qpn_valid;
  logic config_psn_valid;
  logic config_rkey_valid;
  logic config_ring_valid;
  logic config_wr_valid;
  logic config_notify_valid;
  logic config_local_base_valid;
  logic config_flags_valid;
  logic config_address_shape_valid;
  logic config_address_valid;
  logic [64:0] config_expected_commit_address;
  logic [63:0] config_commit_address_value;
  logic source_bound;
  logic [47:0] bound_remote_mac;
  logic [31:0] bound_remote_ip;
  logic [15:0] bound_remote_port;
  logic [63:0] bound_session_id;
  logic [31:0] last_transaction_id;
  logic [31:0] session_fault_reason;
  logic [63:0] consume_candidate;
  logic fault_latched;
  logic fault_event;
  logic fault_preempt;
  logic stale_fault_during_config;
  logic invalidate_after_replay;

  task automatic queue_response(
    input logic [15:0] result_value,
    input logic [7:0] state_value,
    input logic [31:0] reason_value,
    input logic cache_enable
  );
    logic [31:0] status_value;
    begin
      status_value = 32'd0;
      if (endpoint_status.configured) status_value[0] = 1'b1;
      if (endpoint_status.active) status_value[1] = 1'b1;
      if (endpoint_status.drained) status_value[2] = 1'b1;
      if (endpoint_status.fault ||
          state_value == {4'd0, RDCP_SESSION_FAULT_QUIESCING} ||
          state_value == {4'd0, RDCP_SESSION_FAULTED})
        status_value[3] = 1'b1;
      if (state_value == {4'd0, RDCP_SESSION_CLOSED} ||
          state_value == {4'd0, RDCP_SESSION_FAULTED})
        status_value[4] = 1'b1;
      if (endpoint_status.final_commit_acked) status_value[5] = 1'b1;
      if (endpoint_status.credit_stalled) status_value[6] = 1'b1;

      response_descriptor.source <= active_request.identity;
      response_descriptor.result <= result_value;
      response_descriptor.session_state <= state_value;
      response_descriptor.reason <= reason_value;
      response_descriptor.status_bits <= status_value;
      response_descriptor.current_psn <= endpoint_status.current_psn;
      response_descriptor.config_generation <= config_generation;
      response_descriptor.issued_bytes <= endpoint_status.issued_bytes;
      response_descriptor.acked_bytes <= endpoint_status.acked_bytes;
      response_descriptor.published_bytes <= endpoint_status.published_bytes;
      response_descriptor.consumed_bytes <= consumed_bytes;
      response_descriptor.cache_enable <= cache_enable;
      response_valid <= 1'b1;
      engine_state <= ENGINE_RESPONSE_SUBMIT;
      if (cache_enable)
        last_transaction_id <= active_request.identity.transaction_id;
    end
  endtask

  task automatic queue_fault_response(input logic [31:0] reason_value);
    begin
      if (active_request.identity.opcode == RDCP_OP_ABORT)
        queue_response(RDCP_RESULT_OK,
                       {4'd0, RDCP_SESSION_FAULT_QUIESCING},
                       reason_value, 1'b1);
      else
        queue_response(RDCP_RESULT_INVALID_STATE,
                       {4'd0, RDCP_SESSION_FAULT_QUIESCING},
                       reason_value, 1'b1);
    end
  endtask

  assign request_ready = engine_state == ENGINE_WAIT_REQUEST &&
                         !transaction_active && !fault_event;
  assign safe_to_release = session_state == RDCP_SESSION_CLOSED ||
                           session_state == RDCP_SESSION_FAULTED;
  // A drained endpoint may carry a sticky fault from the previous session.
  // Only that pre-existing fault is ignored while CONFIG clears it.
  assign fault_event = endpoint_status.fault && !fault_latched &&
    !(command_action == ACTION_CONFIG && stale_fault_during_config) &&
    (session_state == RDCP_SESSION_CONFIGURING ||
     session_state == RDCP_SESSION_READY ||
     session_state == RDCP_SESSION_RUNNING ||
     session_state == RDCP_SESSION_STOPPING ||
     (engine_state == ENGINE_COMMAND_WAIT &&
      command_action != ACTION_NONE));
  assign fault_preempt = fault_event &&
    engine_state != ENGINE_DISPATCH &&
    engine_state != ENGINE_RESPONSE_SUBMIT &&
    engine_state != ENGINE_REPLAY_SUBMIT &&
    engine_state != ENGINE_RESPONSE_WAIT &&
    engine_state != ENGINE_RETIRE_REQUEST;

  always_ff @(posedge clk) begin
    logic source_matches;
    logic session_matches;
    logic transaction_replay;
    logic transaction_old;
    logic [31:0] consume_reject_reason;

    if (reset) begin
      engine_state <= ENGINE_WAIT_REQUEST;
      command_action <= ACTION_NONE;
      transaction_active <= 1'b0;
      response_valid <= 1'b0;
      replay_valid <= 1'b0;
      cache_invalidate <= 1'b0;
      cfg_valid <= 1'b0;
      start_request <= 1'b0;
      stop_request <= 1'b0;
      command_abort_request <= 1'b0;
      fault_abort_request <= 1'b0;
      fault_latched <= 1'b0;
      stale_fault_during_config <= 1'b0;
      invalidate_after_replay <= 1'b0;
      source_bound <= 1'b0;
      bound_remote_mac <= 48'd0;
      bound_remote_ip <= 32'd0;
      bound_remote_port <= 16'd0;
      bound_session_id <= 64'd0;
      last_transaction_id <= 32'd0;
      session_fault_reason <= 32'd0;
      consumed_bytes <= 64'd0;
      session_state <= RDCP_SESSION_IDLE;
      config_generation <= 32'd0;
    end else begin
      cache_invalidate <= 1'b0;
      fault_abort_request <= 1'b0;
      cfg_valid <= 1'b0;
      start_request <= 1'b0;
      stop_request <= 1'b0;
      command_abort_request <= 1'b0;
      if (!endpoint_status.fault)
        fault_latched <= 1'b0;
      if (!endpoint_status.fault)
        stale_fault_during_config <= 1'b0;

      if (fault_preempt) begin
        fault_latched <= 1'b1;
        session_fault_reason <= endpoint_status.fault_reason;
        session_state <= RDCP_SESSION_FAULT_QUIESCING;
        cache_invalidate <= 1'b1;
        replay_valid <= 1'b0;

        if (engine_state == ENGINE_COMMAND_WAIT) begin
          if (command_action != ACTION_ABORT &&
              command_action != ACTION_SAFETY_ABORT)
            fault_abort_request <= 1'b1;
          if (command_action == ACTION_CONFIG && !cfg_done) begin
            engine_state <= ENGINE_FAULT_DRAIN;
          end else if (transaction_active) begin
            command_action <= ACTION_NONE;
            queue_fault_response(endpoint_status.fault_reason);
          end
        end else begin
          fault_abort_request <= 1'b1;
          if (transaction_active) begin
            command_action <= ACTION_NONE;
            queue_fault_response(endpoint_status.fault_reason);
          end
        end
      end else begin
        if (session_state == RDCP_SESSION_RUNNING && endpoint_status.stopping)
          session_state <= RDCP_SESSION_STOPPING;
        if (session_state == RDCP_SESSION_STOPPING &&
            endpoint_status.final_commit_acked && endpoint_status.drained)
          session_state <= RDCP_SESSION_CLOSED;
        if (session_state == RDCP_SESSION_FAULT_QUIESCING &&
            endpoint_status.drained)
          session_state <= RDCP_SESSION_FAULTED;
        if (fault_event) begin
          fault_latched <= 1'b1;
          session_fault_reason <= endpoint_status.fault_reason;
          session_state <= RDCP_SESSION_FAULT_QUIESCING;
          cache_invalidate <= 1'b1;
          fault_abort_request <= 1'b1;
          if (engine_state == ENGINE_REPLAY_SUBMIT) begin
            cache_invalidate <= 1'b0;
            invalidate_after_replay <= 1'b1;
          end
        end

        case (engine_state)
        ENGINE_WAIT_REQUEST: begin
          if (request_valid && request_ready) begin
            active_request <= request;
            transaction_active <= 1'b1;
            engine_state <= ENGINE_DISPATCH;
          end
        end

        ENGINE_DISPATCH: begin
          source_matches =
            active_request.identity.remote_mac == bound_remote_mac &&
            active_request.identity.remote_ip == bound_remote_ip &&
            active_request.identity.remote_port == bound_remote_port;
          session_matches =
            active_request.identity.session_id == bound_session_id;
          transaction_replay = cache_valid && source_matches && session_matches &&
            active_request.identity.transaction_id == cache_transaction_id &&
            active_request.identity.opcode == cache_opcode;
          transaction_old = active_request.identity.transaction_id <=
                            last_transaction_id;

          if (active_request.parse_result != RDCP_RESULT_OK) begin
            queue_response(active_request.parse_result, {4'd0, session_state},
                           32'd0, 1'b0);
          end else if (active_request.identity.opcode == RDCP_OP_HELLO) begin
            queue_response(RDCP_RESULT_OK, {4'd0, session_state},
                           session_fault_reason, 1'b0);
          end else if (transaction_replay) begin
            if (fault_event) begin
              cache_invalidate <= 1'b0;
              invalidate_after_replay <= 1'b1;
            end
            replay_valid <= 1'b1;
            engine_state <= ENGINE_REPLAY_SUBMIT;
          end else if (active_request.identity.opcode == RDCP_OP_ABORT &&
                       active_request.identity.session_id != 64'd0 &&
                       (session_state == RDCP_SESSION_IDLE ||
                        session_state == RDCP_SESSION_CLOSED ||
                        session_state == RDCP_SESSION_FAULTED) &&
                       (!source_bound || !session_matches)) begin
            source_bound <= 1'b1;
            bound_remote_mac <= active_request.identity.remote_mac;
            bound_remote_ip <= active_request.identity.remote_ip;
            bound_remote_port <= active_request.identity.remote_port;
            bound_session_id <= active_request.identity.session_id;
            session_fault_reason <= 32'd0;
            session_state <= RDCP_SESSION_FAULT_QUIESCING;
            command_action <= ACTION_SAFETY_ABORT;
            command_abort_request <= 1'b1;
            engine_state <= ENGINE_COMMAND_WAIT;
          end else if (active_request.identity.opcode == RDCP_OP_CONFIG) begin
            if (!(session_state == RDCP_SESSION_IDLE ||
                  session_state == RDCP_SESSION_CLOSED ||
                  session_state == RDCP_SESSION_FAULTED)) begin
              if (source_bound && source_matches && session_matches &&
                  transaction_old)
                queue_response(RDCP_RESULT_OLD_TRANSACTION,
                               {4'd0, session_state}, session_fault_reason, 1'b0);
              else
                queue_response(RDCP_RESULT_INVALID_STATE,
                               {4'd0, session_state}, session_fault_reason,
                               source_bound && source_matches && session_matches);
            end else if (source_bound && session_matches) begin
              queue_response(RDCP_RESULT_BAD_SESSION, {4'd0, session_state},
                             session_fault_reason, 1'b0);
            end else begin
              engine_state <= ENGINE_CONFIG_CAPTURE;
            end
          end else if (!source_bound) begin
            if (active_request.identity.opcode == RDCP_OP_STATUS &&
                active_request.identity.session_id == 64'd0)
              queue_response(RDCP_RESULT_OK, {4'd0, session_state},
                             session_fault_reason, 1'b0);
            else
              queue_response(RDCP_RESULT_INVALID_STATE, {4'd0, session_state},
                             session_fault_reason, 1'b0);
          end else if (!source_matches) begin
            queue_response(RDCP_RESULT_BAD_SOURCE, {4'd0, session_state},
                           session_fault_reason, 1'b0);
          end else if (!session_matches) begin
            queue_response(RDCP_RESULT_BAD_SESSION, {4'd0, session_state},
                           session_fault_reason, 1'b0);
          end else if (transaction_old) begin
            queue_response(RDCP_RESULT_OLD_TRANSACTION, {4'd0, session_state},
                           session_fault_reason, 1'b0);
          end else if (fault_event) begin
            command_action <= ACTION_NONE;
            queue_fault_response(endpoint_status.fault_reason);
          end else begin
            case (active_request.identity.opcode)
              RDCP_OP_START: begin
                if (session_state == RDCP_SESSION_READY) begin
                  session_state <= RDCP_SESSION_RUNNING;
                  command_action <= ACTION_START;
                  start_request <= 1'b1;
                  engine_state <= ENGINE_COMMAND_WAIT;
                end else begin
                  queue_response(RDCP_RESULT_INVALID_STATE,
                                 {4'd0, session_state},
                                 session_fault_reason, 1'b1);
                end
              end

              RDCP_OP_STOP: begin
                if (session_state == RDCP_SESSION_RUNNING) begin
                  session_state <= RDCP_SESSION_STOPPING;
                  command_action <= ACTION_STOP;
                  stop_request <= 1'b1;
                  engine_state <= ENGINE_COMMAND_WAIT;
                end else if (session_state == RDCP_SESSION_STOPPING ||
                             session_state == RDCP_SESSION_CLOSED) begin
                  queue_response(RDCP_RESULT_OK, {4'd0, session_state},
                                 32'd0, 1'b1);
                end else begin
                  queue_response(RDCP_RESULT_INVALID_STATE,
                                 {4'd0, session_state},
                                 session_fault_reason, 1'b1);
                end
              end

              RDCP_OP_ABORT: begin
                if (session_state == RDCP_SESSION_FAULTED ||
                    session_state == RDCP_SESSION_FAULT_QUIESCING) begin
                   queue_response(RDCP_RESULT_OK,
                                  {4'd0, session_state},
                                  session_fault_reason, 1'b1);
                end else begin
                  session_state <= RDCP_SESSION_FAULT_QUIESCING;
                  command_action <= ACTION_ABORT;
                  command_abort_request <= 1'b1;
                  engine_state <= ENGINE_COMMAND_WAIT;
                end
              end

              RDCP_OP_STATUS: begin
                queue_response(RDCP_RESULT_OK, {4'd0, session_state},
                               session_fault_reason, 1'b1);
              end

              RDCP_OP_CONSUME: begin
                // OP_CONSUME occupies the same eight wire bytes as the two
                // fixed-width config fields (bytes 62..69).
                consume_candidate <= {
                  active_request.config_fields.remote_qpn,
                  active_request.config_fields.local_psn
                };
                engine_state <= ENGINE_CONSUME_VALIDATE;
              end

              default: begin
                queue_response(RDCP_RESULT_INVALID_STATE,
                               {4'd0, session_state},
                               session_fault_reason, 1'b1);
              end
            endcase
          end
        end

        ENGINE_CONSUME_VALIDATE: begin
          consume_reject_reason = 32'd0;
          if (consume_candidate < consumed_bytes)
            consume_reject_reason[0] = 1'b1;
          if (consume_candidate > endpoint_status.published_bytes)
            consume_reject_reason[1] = 1'b1;
          if (consume_candidate[11:0] != 12'd0)
            consume_reject_reason[2] = 1'b1;

          if (!(session_state == RDCP_SESSION_RUNNING ||
                session_state == RDCP_SESSION_STOPPING ||
                session_state == RDCP_SESSION_CLOSED)) begin
            queue_response(RDCP_RESULT_INVALID_STATE, {4'd0, session_state},
                           session_fault_reason, 1'b1);
          end else if (consume_reject_reason != 32'd0) begin
            queue_response(RDCP_RESULT_INVALID_PROGRESS,
                           {4'd0, session_state},
                           consume_reject_reason, 1'b1);
          end else begin
            consumed_bytes <= consume_candidate;
            queue_response(RDCP_RESULT_OK, {4'd0, session_state}, 32'd0, 1'b1);
            response_descriptor.consumed_bytes <= consume_candidate;
          end
        end

        ENGINE_CONFIG_CAPTURE: begin
          cfg_remote_mac <= active_request.identity.remote_mac;
          cfg_remote_ip <= active_request.identity.remote_ip;
          cfg_remote_qpn <=
            active_request.config_fields.remote_qpn[23:0];
          cfg_local_psn <=
            active_request.config_fields.local_psn[23:0];
          cfg_remote_base <=
            active_request.config_fields.remote_base[47:0];
          cfg_rkey <= active_request.config_fields.rkey;
          cfg_ring_size <= active_request.config_fields.ring_size;
          cfg_wr_size <= active_request.config_fields.wr_size;
          cfg_notify_interval_bytes <=
            active_request.config_fields.notify_interval_bytes;
          cfg_local_base <= active_request.config_fields.local_base;
          cfg_commit_remote_addr <=
            active_request.config_fields.commit_address[47:0];
          cfg_enable_immediate <= active_request.config_fields.flags[0];

          config_session_valid <= active_request.identity.session_id != 64'd0;
          config_qpn_valid <= active_request.config_fields.remote_qpn != 32'd0 &&
                              active_request.config_fields.remote_qpn[31:24] == 8'd0;
          config_psn_valid <= active_request.config_fields.local_psn != 32'd0 &&
                              active_request.config_fields.local_psn[31:24] == 8'd0;
          config_rkey_valid <= active_request.config_fields.rkey != 32'd0;
          config_ring_valid <=
            active_request.config_fields.ring_size == 32'h4000_0000;
          config_wr_valid <=
            active_request.config_fields.wr_size == 32'h00A0_0000;
          config_notify_valid <=
            active_request.config_fields.notify_interval_bytes == 32'h00A0_0000;
          config_local_base_valid <=
            active_request.config_fields.local_base == 64'd0;
          config_flags_valid <=
            (active_request.config_fields.flags & 32'hFFFF_FFFE) == 32'd0 &&
            active_request.config_fields.reserved == 32'd0;
          config_address_shape_valid <=
            active_request.config_fields.remote_base[63:48] == 16'd0 &&
            active_request.config_fields.commit_address[63:48] == 16'd0 &&
            active_request.config_fields.commit_address[5:0] == 6'd0;
          config_expected_commit_address <=
            {1'b0, active_request.config_fields.remote_base} +
            {33'd0, active_request.config_fields.ring_size};
          config_commit_address_value <=
            active_request.config_fields.commit_address;
          engine_state <= ENGINE_CONFIG_ADDRESS;
        end

        ENGINE_CONFIG_ADDRESS: begin
          config_address_valid <= config_address_shape_valid &&
            !config_expected_commit_address[64] &&
            config_commit_address_value == config_expected_commit_address[63:0];
          engine_state <= ENGINE_CONFIG_VALIDATE;
        end

        ENGINE_CONFIG_VALIDATE: begin
          if (!(config_session_valid && config_qpn_valid && config_psn_valid &&
                config_rkey_valid && config_ring_valid && config_wr_valid &&
                config_notify_valid && config_local_base_valid &&
                config_flags_valid && config_address_valid)) begin
            queue_response(RDCP_RESULT_INVALID_CONFIG, {4'd0, session_state},
                           32'h0000_0001, 1'b0);
          end else if (!cfg_ready) begin
            queue_response(RDCP_RESULT_BUSY, {4'd0, session_state},
                           32'd0, 1'b0);
          end else begin
            command_action <= ACTION_CONFIG;
            stale_fault_during_config <= endpoint_status.fault;
            source_bound <= 1'b1;
            bound_remote_mac <= active_request.identity.remote_mac;
            bound_remote_ip <= active_request.identity.remote_ip;
            bound_remote_port <= active_request.identity.remote_port;
            bound_session_id <= active_request.identity.session_id;
            session_fault_reason <= 32'd0;
            session_state <= RDCP_SESSION_CONFIGURING;
            cache_invalidate <= 1'b1;
            cfg_valid <= 1'b1;
            engine_state <= ENGINE_COMMAND_WAIT;
          end
        end

        ENGINE_COMMAND_WAIT: begin
          case (command_action)
            ACTION_CONFIG: begin
              if (cfg_done) begin
                if (cfg_accepted) begin
                  config_generation <= config_generation + 32'd1;
                  consumed_bytes <= 64'd0;
                  session_state <= RDCP_SESSION_READY;
                  queue_response(RDCP_RESULT_OK,
                                 {4'd0, RDCP_SESSION_READY}, 32'd0, 1'b1);
                  response_descriptor.config_generation <=
                    config_generation + 32'd1;
                  response_descriptor.consumed_bytes <= 64'd0;
                end else begin
                  source_bound <= 1'b0;
                  bound_session_id <= 64'd0;
                  session_state <= RDCP_SESSION_IDLE;
                  queue_response(RDCP_RESULT_INVALID_CONFIG,
                                 {4'd0, RDCP_SESSION_IDLE},
                                 cfg_reject_reason, 1'b0);
                end
                command_action <= ACTION_NONE;
              end
            end

            ACTION_START: begin
              queue_response(RDCP_RESULT_OK,
                             {4'd0, RDCP_SESSION_RUNNING}, 32'd0, 1'b1);
              command_action <= ACTION_NONE;
            end

            ACTION_STOP: begin
              queue_response(RDCP_RESULT_OK,
                             {4'd0, RDCP_SESSION_STOPPING}, 32'd0, 1'b1);
              command_action <= ACTION_NONE;
            end

            ACTION_ABORT,
            ACTION_SAFETY_ABORT: begin
              queue_response(RDCP_RESULT_OK,
                             {4'd0, RDCP_SESSION_FAULT_QUIESCING},
                             session_fault_reason, 1'b1);
              command_action <= ACTION_NONE;
            end

            default: begin
              queue_response(RDCP_RESULT_INVALID_STATE,
                             {4'd0, session_state}, 32'hFFFF_FFFF, 1'b0);
            end
          endcase
        end

        ENGINE_FAULT_DRAIN: begin
          if (cfg_done) begin
            command_action <= ACTION_NONE;
            queue_fault_response(session_fault_reason);
          end
        end

        ENGINE_RESPONSE_SUBMIT: begin
          if (response_valid && response_ready) begin
            response_valid <= 1'b0;
            engine_state <= ENGINE_RESPONSE_WAIT;
          end
        end

        ENGINE_REPLAY_SUBMIT: begin
          if (replay_valid && replay_ready) begin
            replay_valid <= 1'b0;
            if (invalidate_after_replay || fault_event) begin
              cache_invalidate <= 1'b1;
              invalidate_after_replay <= 1'b0;
            end
            engine_state <= ENGINE_RESPONSE_WAIT;
          end
        end

        ENGINE_RESPONSE_WAIT: begin
          if (response_done)
            engine_state <= ENGINE_RETIRE_REQUEST;
        end

        ENGINE_RETIRE_REQUEST: begin
          transaction_active <= 1'b0;
          engine_state <= ENGINE_WAIT_REQUEST;
        end

        default: begin
          transaction_active <= 1'b0;
          response_valid <= 1'b0;
          replay_valid <= 1'b0;
          engine_state <= ENGINE_WAIT_REQUEST;
        end
      endcase
      end
    end
  end
endmodule
