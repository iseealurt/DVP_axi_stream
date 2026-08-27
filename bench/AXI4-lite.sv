`timescale 1ns/1ns
// ------------------------------- Definiiton of interface -------------------------------
interface if_axil_aw#(
    parameter AWIDTH = 32
)(
    input bit clk
);
    logic awready;
    logic awvalid;
    logic rst;
    logic [AWIDTH-1:0] awaddr;
    logic [1:0] axif_awport;
    
    clocking master_cb @(posedge clk);
        input awready;
        output awvalid,awaddr,axif_awport;
    endclocking 

    clocking slave_cb @(posedge clk);
        output awready;
        input awvalid,awaddr,axif_awport;
    endclocking 

    clocking monitor_cb @(posedge clk);
        input awready,awvalid,awaddr,axif_awport;
    endclocking 
    modport MASTER(
        clocking master_cb ,
        input rst 
    );
    modport SLAVE(
        clocking slave_cb ,
        input rst 
    );
    modport MONITOR(
        clocking monitor_cb,
        input rst 
    );
endinterface

interface if_axil_ar#(
    parameter AWIDTH = 32
)(
    input bit clk
);
    logic arready;
    logic arvalid;
    logic rst;
    logic [AWIDTH-1:0] araddr;
    logic [1:0] axif_arport;
    
    clocking master_cb @(posedge clk);
        input arready;
        output arvalid,araddr,axif_arport;
    endclocking 

    clocking slave_cb @(posedge clk);
        output arready;
        input arvalid,araddr,axif_arport;
    endclocking 

    clocking monitor_cb @(posedge clk);
        input arready,arvalid,araddr,axif_arport;
    endclocking 
    modport MASTER(
        clocking master_cb ,
        input rst 
    );
    modport SLAVE(
        clocking slave_cb ,
        input rst 
    );
    modport MONITOR(
        clocking monitor_cb ,
        input rst 
    );
endinterface

interface if_axil_dw#(
    parameter DWIDTH = 128
)(
    input bit clk
);
    logic wready;
    logic wvalid;
    logic rst;
    logic [DWIDTH-1:0] wdata;
    logic [DWIDTH/8-1:0] wstrb;
    
    clocking master_cb @(posedge clk);
        input wready;
        output wvalid,wdata,wstrb;
    endclocking 

    clocking slave_cb @(posedge clk);
        output wready;
        input wvalid,wdata,wstrb;
    endclocking 

    clocking monitor_cb @(posedge clk);
        input wready,wvalid,wdata,wstrb;
    endclocking 
    modport MASTER(
        clocking master_cb ,
        input rst 
    );
    modport SLAVE(
        clocking slave_cb ,
        input rst 
    );
    modport MONITOR(
        clocking monitor_cb ,
        input rst 
    );
endinterface

interface if_axil_dr#(
    parameter DWIDTH = 128,
    parameter IDWIDTH = 4
)(
    input bit clk
);
    logic rvalid;
    logic rst;
    logic [DWIDTH-1:0] rdata;
    logic [1:0] rresp;
    logic [IDWIDTH-1:0] axif_rid;
    logic rready;
    
    clocking master_cb @(posedge clk);
        input rvalid,rdata,rresp,axif_rid;
        output rready;
    endclocking 

    clocking slave_cb @(posedge clk);
        output rvalid,rdata,rresp,axif_rid;
        input rready;
    endclocking 

    clocking monitor_cb @(posedge clk);
        input rvalid,rdata,rresp,axif_rid,rready;
    endclocking 
    modport MASTER(
        clocking master_cb ,
        input rst 
    );
    modport SLAVE(
        clocking slave_cb ,
        input rst 
    );
    modport MONITOR(
        clocking monitor_cb ,
        input rst 
    );
endinterface

interface if_axil_wb#(
    parameter IDWIDTH = 4
)(
    input bit clk
);
    logic bvalid;
    logic rst;
    logic [1:0] bresp;
    logic [IDWIDTH-1:0] axif_bid;
    logic bready;
    
    clocking master_cb @(posedge clk);
        input bvalid,bresp,axif_bid;
        output bready;
    endclocking 

    clocking slave_cb @(posedge clk);
        output bvalid,bresp,axif_bid;
        input bready;
    endclocking 

    clocking monitor_cb @(posedge clk);
        input bvalid,bresp,axif_bid,bready;
    endclocking 
    modport MASTER(
        clocking master_cb ,
        input rst 
    );
    modport SLAVE(
        clocking slave_cb ,
        input rst 
    );
    modport MONITOR(
        clocking monitor_cb ,
        input rst 
    );
endinterface

package axil_test_pkg;
  class axil_driver#(
    parameter int ADDR_W = 32 ,
    parameter int DATA_W = 128 ,
    parameter int ID_W   = 4
    );
      // ------------------------------- Definiiton of enum -------------------------------
      typedef enum logic [1:0] {OKAY,RSV,SLVERR,DECERR} axil_resp_state_e;
      typedef enum logic [1:0] {
        PASS,
        FAIL,
        TIMEOUT
      } test_result_e;

      typedef struct {
        int               txn_id;        // 事务 ID，用于复现
        string            txn_name;     // 用例名
        logic [ADDR_W-1:0] txn_addr;         // 本次地址
        logic [DATA_W-1:0] txn_data;         // 本次数据
        logic [DATA_W/8-1:0] txn_strb; 
        test_result_e     txn_result;        // 结果
        string            txn_reason;        // 失败原因
      } txn_result_e;
      // ------------------------------- axil_aw -------------------------------
      virtual if_axil_aw #(ADDR_W).MASTER vif_mst_axil_aw; // master
      virtual if_axil_aw #(ADDR_W).SLAVE vif_slv_axil_aw; // slave
      virtual if_axil_aw #(ADDR_W).MONITOR vif_mnt_axil_aw; // monitor
      // ------------------------------- axil_ar -------------------------------
      virtual if_axil_ar #(ADDR_W).MASTER vif_mst_axil_ar; // master
      virtual if_axil_ar #(ADDR_W).SLAVE vif_slv_axil_ar; // slave
      virtual if_axil_ar #(ADDR_W).MONITOR vif_mnt_axil_ar; // monitor
      // ------------------------------- axil_dw -------------------------------
      virtual if_axil_dw #(DATA_W).MASTER vif_mst_axil_dw; // master
      virtual if_axil_dw #(DATA_W).SLAVE vif_slv_axil_dw; // slave
      virtual if_axil_dw #(DATA_W).MONITOR vif_mnt_axil_dw; // monitor
      // ------------------------------- axil_dr -------------------------------
      virtual if_axil_dr #(DATA_W, ID_W).MASTER vif_mst_axil_dr; // master
      virtual if_axil_dr #(DATA_W, ID_W).SLAVE vif_slv_axil_dr; // slave
      virtual if_axil_dr #(DATA_W, ID_W).MONITOR vif_mnt_axil_dr; // monitor
      // ------------------------------- axil_wb -------------------------------
      virtual if_axil_wb #(ID_W).MASTER vif_mst_axil_wb; // master
      virtual if_axil_wb #(ID_W).SLAVE vif_slv_axil_wb; // slave
      virtual if_axil_wb #(ID_W).MONITOR vif_mnt_axil_wb; // monitor

      // ------------------------------- axil_aw -------------------------------
      function mst_axil_aw_new(virtual if_axil_aw #(ADDR_W).MASTER vif_mst_axil_aw);
          this.vif_mst_axil_aw = vif_mst_axil_aw;
      endfunction
      function slv_axil_aw_new(virtual if_axil_aw #(ADDR_W).SLAVE vif_slv_axil_aw);
          this.vif_slv_axil_aw = vif_slv_axil_aw;
      endfunction
      function mnt_axil_aw_new(virtual if_axil_aw #(ADDR_W).MONITOR vif_mnt_axil_aw);
          this.vif_mnt_axil_aw = vif_mnt_axil_aw;
      endfunction
      // ------------------------------- axil_ar -------------------------------
      function mst_axil_ar_new(virtual if_axil_ar #(ADDR_W).MASTER vif_mst_axil_ar);
          this.vif_mst_axil_ar = vif_mst_axil_ar;
      endfunction
      function slv_axil_ar_new(virtual if_axil_ar #(ADDR_W).SLAVE vif_slv_axil_ar);
          this.vif_slv_axil_ar = vif_slv_axil_ar;
      endfunction
      function mnt_axil_ar_new(virtual if_axil_ar #(ADDR_W).MONITOR vif_mnt_axil_ar);
          this.vif_mnt_axil_ar = vif_mnt_axil_ar;
      endfunction
      // ------------------------------- axil_dw -------------------------------
      function mst_axil_dw_new(virtual if_axil_dw #(DATA_W).MASTER vif_mst_axil_dw);
          this.vif_mst_axil_dw = vif_mst_axil_dw;
      endfunction
      function slv_axil_dw_new(virtual if_axil_dw #(DATA_W).SLAVE vif_slv_axil_dw);
          this.vif_slv_axil_dw = vif_slv_axil_dw;
      endfunction
      function mnt_axil_dw_new(virtual if_axil_dw #(DATA_W).MONITOR vif_mnt_axil_dw);
          this.vif_mnt_axil_dw = vif_mnt_axil_dw;
      endfunction
      // ------------------------------- axil_dr -------------------------------
      function mst_axil_dr_new(virtual if_axil_dr #(DATA_W, ID_W).MASTER vif_mst_axil_dr);
          this.vif_mst_axil_dr = vif_mst_axil_dr;
      endfunction
      function slv_axil_dr_new(virtual if_axil_dr #(DATA_W, ID_W).SLAVE vif_slv_axil_dr);
          this.vif_slv_axil_dr = vif_slv_axil_dr;
      endfunction
      function mnt_axil_dr_new(virtual if_axil_dr #(DATA_W, ID_W).MONITOR vif_mnt_axil_dr);
          this.vif_mnt_axil_dr = vif_mnt_axil_dr;
      endfunction
      // ------------------------------- axil_wb -------------------------------
      function mst_axil_wb_new(virtual if_axil_wb #(ID_W).MASTER vif_mst_axil_wb);
          this.vif_mst_axil_wb = vif_mst_axil_wb;
      endfunction
      function slv_axil_wb_new(virtual if_axil_wb #(ID_W).SLAVE vif_slv_axil_wb);
          this.vif_slv_axil_wb = vif_slv_axil_wb;
      endfunction
      function mnt_axil_wb_new(virtual if_axil_wb #(ID_W).MONITOR vif_mnt_axil_wb);
          this.vif_mnt_axil_wb = vif_mnt_axil_wb;
      endfunction
      
      task automatic mst_write_reg(
        input int task_id,
        input string task_name,
        input int max_timeout_cycle,
        input bit reset_assert,
        input logic [ADDR_W-1:0] addr,
        input logic [DATA_W-1:0] data,
        input logic [DATA_W/8-1:0] wstrb,
        output txn_result_e result
      );
        string err_msg;
        axil_resp_state_e wb_result;
        bit txn_done;
        result.txn_id = task_id;
        result.txn_name = task_name;
        result.txn_addr = addr;
        result.txn_data = data;
        result.txn_strb = wstrb;
        result.txn_result = PASS;
        result.txn_reason = "";
        //reset all 
        if(reset_assert) begin
          vif_mst_axil_aw.rst = 1'b1;
          vif_mst_axil_dw.rst = 1'b1;
          vif_mst_axil_wb.rst = 1'b1;
          repeat(10) @(vif_mst_axil_aw.cb);
          vif_mst_axil_aw.rst = 1'b0;
          vif_mst_axil_dw.rst = 1'b0;
          vif_mst_axil_wb.rst = 1'b0;
        end
        fork : mst_write_reg_fork
          begin : aw_test
            @(vif_mst_axil_aw.cb);
            vif_mst_axil_aw.awvalid <= 1'b1;
            vif_mst_axil_aw.awaddr <= addr;
            wait (vif_mst_axil_aw.awvalid && vif_mst_axil_aw.awready) vif_mst_axil_aw.awvalid <= 1'b0;            
            wait (txn_done); //事务结束前不退出本分支
          end
          begin : dw_test
            @(vif_mst_axil_dw.cb);
            vif_mst_axil_dw.wvalid <= 1'b1;
            vif_mst_axil_dw.wdata <= data;
            vif_mst_axil_dw.wstrb <= wstrb;
            wait (vif_mst_axil_dw.wvalid && vif_mst_axil_dw.wready) vif_mst_axil_dw.wvalid <= 1'b0;
            wait (txn_done); //事务结束前不退出本分支
          end
          begin : wb_test
            @(vif_mst_axil_wb.cb);
            vif_mst_axil_wb.bready <= 1'b1; //事务一开始就使能，随时可收响应
            wait (vif_mst_axil_wb.bvalid && vif_mst_axil_wb.bready) begin
            wb_result = vif_mst_axil_wb.bresp;
            vif_mst_axil_wb.bready <= 1'b0;
            end
            txn_done = 1'b1; //B握手完成，事务结束
          end
          begin : timeout_monitor
            repeat(max_timeout_cycle) @(vif_mst_axil_aw.cb);
            if (!txn_done) begin
              err_msg = $sformatf("@%0t [TIMEOUT] task %0d timeout for %0d cycles",$time,task_id,max_timeout_cycle);
              result.txn_reason = err_msg;
              result.txn_result = TIMEOUT;
              $error("%s",err_msg);
              txn_done = 1'b1;
            end
          end
        join_any
        disable fork; //事务完成或超时，回收所有线程
        if(result.txn_result == TIMEOUT) begin
            return;
        end
        else if(wb_result != OKAY) begin
          result.txn_result = FAIL;
          result.txn_reason = wb_result.name();
          return;
        end
        else begin
          result.txn_result = PASS;
          result.txn_reason = wb_result.name();
          return;
        end
      endtask 
  endclass
endpackage
