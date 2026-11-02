`timescale 1ns/1ps

module transport_timer_scale_tb;

    localparam longint unsigned CLOCK_PERIOD_PS = 4_000;
    localparam longint unsigned MAX_QPS = 256;
    localparam longint unsigned QP_SCAN_PERIOD_PS = CLOCK_PERIOD_PS * MAX_QPS;

    function automatic longint unsigned timeout_ticks(input longint unsigned timeout_us);
        timeout_ticks = ((timeout_us * 1_000_000) / CLOCK_PERIOD_PS / MAX_QPS) + 1;
    endfunction

    task automatic check_timeout(
        input longint unsigned timeout_us,
        input longint unsigned expected_ticks
    );
        longint unsigned ticks;
        longint unsigned requested_ps;
        longint unsigned effective_ps;
        begin
            ticks = timeout_ticks(timeout_us);
            requested_ps = timeout_us * 1_000_000;

            // The timer expires on the scan after the counter reaches zero.
            effective_ps = (ticks + 1) * QP_SCAN_PERIOD_PS;

            if (ticks != expected_ticks)
                $fatal(1, "%0d us threshold mismatch: expected %0d, got %0d",
                       timeout_us, expected_ticks, ticks);
            if (effective_ps < requested_ps)
                $fatal(1, "%0d us timeout fires early", timeout_us);
            if ((effective_ps - requested_ps) > (2 * QP_SCAN_PERIOD_PS))
                $fatal(1, "%0d us timeout error exceeds two QP scans", timeout_us);

            $display("timeout=%0d us ticks=%0d effective=%0d ps",
                     timeout_us, ticks, effective_ps);
        end
    endtask

    initial begin
        check_timeout(1_000, 977);
        check_timeout(5_000, 4_883);
        check_timeout(12_000, 11_719);
        check_timeout(64_000, 62_501);
        $display("PASS: transport_timer_scale_tb");
        $finish;
    end

endmodule
