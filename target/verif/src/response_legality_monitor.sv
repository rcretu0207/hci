/**
 * HCI-only response legality monitor
 *
 * Tracks the number of response-generating granted transactions still pending
 * for each driver-facing master and checks that:
 *  - a response is never visible unless at least one granted transaction is pending;
 *  - completed responses never outnumber response-generating grants;
 *  - end_resp is asserted only after the master's pending-response count returns to zero.
 */

module response_legality_monitor
  import tb_hci_pkg::*;
#(
  parameter int unsigned N_MASTER = 4,
  parameter int unsigned N_HWPE = 1
) (
  input logic                clk_i,
  input logic                rst_ni,
  input logic [N_MASTER-1:0] end_resp_i,
  hci_core_intf.monitor      hci_driver_log_if [0:N_MASTER-N_HWPE-1],
  hci_core_intf.monitor      hci_driver_hwpe_if [0:N_HWPE-1]
);

  localparam int unsigned N_LOG_MASTERS = N_MASTER - N_HWPE;

  function automatic logic hwpe_rsp_expected(
    input int unsigned master_idx_i,
    input logic        is_read_i
  );
    return is_read_i || !FILTER_WRITE_R_VALID[master_idx_i];
  endfunction

  logic log_req[N_LOG_MASTERS];
  logic log_gnt[N_LOG_MASTERS];
  logic log_r_valid[N_LOG_MASTERS];
  logic log_r_ready[N_LOG_MASTERS];
  logic log_end_resp[N_LOG_MASTERS];
  logic hwpe_req[N_HWPE];
  logic hwpe_gnt[N_HWPE];
  logic hwpe_r_valid[N_HWPE];
  logic hwpe_r_ready[N_HWPE];
  logic hwpe_wen[N_HWPE];
  logic hwpe_end_resp[N_HWPE];

  int unsigned pending_log_q[N_LOG_MASTERS];
  int unsigned granted_log_q[N_LOG_MASTERS];
  int unsigned retired_log_q[N_LOG_MASTERS];
  int unsigned pending_hwpe_q[N_HWPE];
  int unsigned granted_hwpe_q[N_HWPE];
  int unsigned retired_hwpe_q[N_HWPE];

  generate
    for (genvar ii = 0; ii < N_LOG_MASTERS; ii++) begin : gen_log_bind
      assign log_req[ii] = hci_driver_log_if[ii].req;
      assign log_gnt[ii] = hci_driver_log_if[ii].gnt;
      assign log_r_valid[ii] = hci_driver_log_if[ii].r_valid;
      assign log_r_ready[ii] = hci_driver_log_if[ii].r_ready;
      assign log_end_resp[ii] = end_resp_i[ii];
    end

    for (genvar ii = 0; ii < N_HWPE; ii++) begin : gen_hwpe_bind
      assign hwpe_req[ii] = hci_driver_hwpe_if[ii].req;
      assign hwpe_gnt[ii] = hci_driver_hwpe_if[ii].gnt;
      assign hwpe_r_valid[ii] = hci_driver_hwpe_if[ii].r_valid;
      assign hwpe_r_ready[ii] = hci_driver_hwpe_if[ii].r_ready;
      assign hwpe_wen[ii] = hci_driver_hwpe_if[ii].wen;
      assign hwpe_end_resp[ii] = end_resp_i[N_LOG_MASTERS + ii];
    end
  endgenerate

  generate
    for (genvar ii = 0; ii < N_LOG_MASTERS; ii++) begin : gen_log_monitor
      always_ff @(posedge clk_i or negedge rst_ni) begin
        int signed pending_delta;
        int unsigned visible_pending;
        int unsigned pending_after_cycle;

        if (!rst_ni) begin
          pending_log_q[ii] <= '0;
          granted_log_q[ii] <= '0;
          retired_log_q[ii] <= '0;
        end else begin
          pending_delta = 0;

          if (log_req[ii] && log_gnt[ii]) begin
            pending_delta = pending_delta + 1;
            granted_log_q[ii] <= granted_log_q[ii] + 1;
          end

          visible_pending = pending_log_q[ii] + ((log_req[ii] && log_gnt[ii]) ? 1 : 0);

          if (log_r_valid[ii] && (visible_pending == 0)) begin
            $fatal(
              1,
              "Response visible on master_log_%0d without any granted transaction pending.",
              ii
            );
          end

          if (log_r_valid[ii] && log_r_ready[ii]) begin
            if (visible_pending == 0) begin
              $fatal(
                1,
                "Completed response on master_log_%0d without any granted transaction pending.",
                ii
              );
            end
            pending_delta = pending_delta - 1;
            retired_log_q[ii] <= retired_log_q[ii] + 1;
          end

          pending_after_cycle = pending_log_q[ii] + pending_delta;
          if (log_end_resp[ii] && (pending_after_cycle != 0)) begin
            $fatal(
              1,
              "master_log_%0d asserted end_resp with %0d responses still pending.",
              ii,
              pending_after_cycle
            );
          end

          pending_log_q[ii] <= pending_after_cycle;
        end
      end
    end

    for (genvar ii = 0; ii < N_HWPE; ii++) begin : gen_hwpe_monitor
      always_ff @(posedge clk_i or negedge rst_ni) begin
        int signed pending_delta;
        int unsigned visible_pending;
        int unsigned pending_after_cycle;

        if (!rst_ni) begin
          pending_hwpe_q[ii] <= '0;
          granted_hwpe_q[ii] <= '0;
          retired_hwpe_q[ii] <= '0;
        end else begin
          pending_delta = 0;

          if (hwpe_req[ii] && hwpe_gnt[ii] && hwpe_rsp_expected(ii, hwpe_wen[ii])) begin
            pending_delta = pending_delta + 1;
            granted_hwpe_q[ii] <= granted_hwpe_q[ii] + 1;
          end

          visible_pending = pending_hwpe_q[ii]
              + ((hwpe_req[ii] && hwpe_gnt[ii] && hwpe_rsp_expected(ii, hwpe_wen[ii])) ? 1 : 0);

          if (hwpe_r_valid[ii] && (visible_pending == 0)) begin
            $fatal(
              1,
              "Response visible on master_hwpe_%0d without any granted transaction pending.",
              ii
            );
          end

          if (hwpe_r_valid[ii] && hwpe_r_ready[ii]) begin
            if (visible_pending == 0) begin
              $fatal(
                1,
                "Completed response on master_hwpe_%0d without any granted transaction pending.",
                ii
              );
            end
            pending_delta = pending_delta - 1;
            retired_hwpe_q[ii] <= retired_hwpe_q[ii] + 1;
          end

          pending_after_cycle = pending_hwpe_q[ii] + pending_delta;
          if (hwpe_end_resp[ii] && (pending_after_cycle != 0)) begin
            $fatal(
              1,
              "master_hwpe_%0d asserted end_resp with %0d responses still pending.",
              ii,
              pending_after_cycle
            );
          end

          pending_hwpe_q[ii] <= pending_after_cycle;
        end
      end
    end
  endgenerate

  final begin
    bit pass;
    pass = 1'b1;

    for (int ii = 0; ii < N_LOG_MASTERS; ii++) begin
      if (pending_log_q[ii] != 0) begin
        $error(
          "master_log_%0d finished with %0d pending responses in response_legality_monitor.",
          ii,
          pending_log_q[ii]
        );
        pass = 1'b0;
      end
      if (retired_log_q[ii] > granted_log_q[ii]) begin
        $error(
          "master_log_%0d retired more responses (%0d) than grants (%0d).",
          ii,
          retired_log_q[ii],
          granted_log_q[ii]
        );
        pass = 1'b0;
      end
    end

    for (int ii = 0; ii < N_HWPE; ii++) begin
      if (pending_hwpe_q[ii] != 0) begin
        $error(
          "master_hwpe_%0d finished with %0d pending responses in response_legality_monitor.",
          ii,
          pending_hwpe_q[ii]
        );
        pass = 1'b0;
      end
      if (retired_hwpe_q[ii] > granted_hwpe_q[ii]) begin
        $error(
          "master_hwpe_%0d retired more responses (%0d) than response-generating grants (%0d).",
          ii,
          retired_hwpe_q[ii],
          granted_hwpe_q[ii]
        );
        pass = 1'b0;
      end
    end

    if (pass) begin
      $display("Response legality monitor: PASS");
    end
  end

endmodule
