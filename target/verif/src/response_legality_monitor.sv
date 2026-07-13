/**
 * HCI-only response legality monitor
 *
 * Tracks the number of granted transactions with a response still pending for
 * each driver-facing master and checks that:
 *  - a response is never visible unless at least one granted transaction is pending;
 *  - completed responses never outnumber granted transactions;
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

  localparam int unsigned N_LOG_MASTERS_LOCAL = N_MASTER - N_HWPE;

  int unsigned pending_log_q[N_LOG_MASTERS_LOCAL];
  int unsigned granted_log_q[N_LOG_MASTERS_LOCAL];
  int unsigned retired_log_q[N_LOG_MASTERS_LOCAL];
  int unsigned pending_hwpe_q[N_HWPE];
  int unsigned granted_hwpe_q[N_HWPE];
  int unsigned retired_hwpe_q[N_HWPE];

  generate
    for (genvar gi = 0; gi < N_LOG_MASTERS_LOCAL; gi++) begin : gen_log
      always_ff @(posedge clk_i or negedge rst_ni) begin
        int signed pending_delta;
        int unsigned visible_pending;
        int unsigned pending_after_cycle;

        if (!rst_ni) begin
          pending_log_q[gi] <= '0;
          granted_log_q[gi] <= '0;
          retired_log_q[gi] <= '0;
        end else begin
          pending_delta = 0;

          if (hci_driver_log_if[gi].req && hci_driver_log_if[gi].gnt) begin
            pending_delta = pending_delta + 1;
            granted_log_q[gi] <= granted_log_q[gi] + 1;
          end

          visible_pending = pending_log_q[gi] + ((hci_driver_log_if[gi].req && hci_driver_log_if[gi].gnt) ? 1 : 0);

          if (hci_driver_log_if[gi].r_valid && (visible_pending == 0)) begin
            $fatal(
              1,
              "Response visible on master_log_%0d without any granted transaction pending.",
              gi
            );
          end

          if (hci_driver_log_if[gi].r_valid && hci_driver_log_if[gi].r_ready) begin
            if (visible_pending == 0) begin
              $fatal(
                1,
                "Completed response on master_log_%0d without any granted transaction pending.",
                gi
              );
            end
            pending_delta = pending_delta - 1;
            retired_log_q[gi] <= retired_log_q[gi] + 1;
          end

          pending_after_cycle = pending_log_q[gi] + pending_delta;
          if (end_resp_i[gi] && (pending_after_cycle != 0)) begin
            $fatal(
              1,
              "master_log_%0d asserted end_resp with %0d responses still pending.",
              gi,
              pending_after_cycle
            );
          end

          pending_log_q[gi] <= pending_after_cycle;
        end
      end
    end

    for (genvar gi = 0; gi < N_HWPE; gi++) begin : gen_hwpe
      always_ff @(posedge clk_i or negedge rst_ni) begin
        int signed pending_delta;
        int unsigned visible_pending;
        int unsigned pending_after_cycle;

        if (!rst_ni) begin
          pending_hwpe_q[gi] <= '0;
          granted_hwpe_q[gi] <= '0;
          retired_hwpe_q[gi] <= '0;
        end else begin
          pending_delta = 0;

          if (hci_driver_hwpe_if[gi].req && hci_driver_hwpe_if[gi].gnt) begin
            pending_delta = pending_delta + 1;
            granted_hwpe_q[gi] <= granted_hwpe_q[gi] + 1;
          end

          visible_pending = pending_hwpe_q[gi] + ((hci_driver_hwpe_if[gi].req && hci_driver_hwpe_if[gi].gnt) ? 1 : 0);

          if (hci_driver_hwpe_if[gi].r_valid && (visible_pending == 0)) begin
            $fatal(
              1,
              "Response visible on master_hwpe_%0d without any granted transaction pending.",
              gi
            );
          end

          if (hci_driver_hwpe_if[gi].r_valid && hci_driver_hwpe_if[gi].r_ready) begin
            if (visible_pending == 0) begin
              $fatal(
                1,
                "Completed response on master_hwpe_%0d without any granted transaction pending.",
                gi
              );
            end
            pending_delta = pending_delta - 1;
            retired_hwpe_q[gi] <= retired_hwpe_q[gi] + 1;
          end

          pending_after_cycle = pending_hwpe_q[gi] + pending_delta;
          if (end_resp_i[N_LOG_MASTERS_LOCAL + gi] && (pending_after_cycle != 0)) begin
            $fatal(
              1,
              "master_hwpe_%0d asserted end_resp with %0d responses still pending.",
              gi,
              pending_after_cycle
            );
          end

          pending_hwpe_q[gi] <= pending_after_cycle;
        end
      end
    end
  endgenerate

  final begin
    bit pass;
    pass = 1'b1;

    for (int i = 0; i < N_LOG_MASTERS_LOCAL; i++) begin
      if (pending_log_q[i] != 0) begin
        $error(
          "master_log_%0d finished with %0d pending responses in response_legality_monitor.",
          i,
          pending_log_q[i]
        );
        pass = 1'b0;
      end
      if (retired_log_q[i] > granted_log_q[i]) begin
        $error(
          "master_log_%0d retired more responses (%0d) than grants (%0d).",
          i,
          retired_log_q[i],
          granted_log_q[i]
        );
        pass = 1'b0;
      end
    end

    for (int i = 0; i < N_HWPE; i++) begin
      if (pending_hwpe_q[i] != 0) begin
        $error(
          "master_hwpe_%0d finished with %0d pending responses in response_legality_monitor.",
          i,
          pending_hwpe_q[i]
        );
        pass = 1'b0;
      end
      if (retired_hwpe_q[i] > granted_hwpe_q[i]) begin
        $error(
          "master_hwpe_%0d retired more responses (%0d) than grants (%0d).",
          i,
          retired_hwpe_q[i],
          granted_hwpe_q[i]
        );
        pass = 1'b0;
      end
    end

    if (pass) begin
      $display("Response legality monitor: PASS");
    end
  end

endmodule
