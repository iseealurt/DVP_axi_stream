`timescale 1ns/1ps
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
  // ------------------------------- Definiiton of common types -------------------------------
  typedef enum logic [1:0] {
    PASS,
    FAIL,
    TIMEOUT
  } test_result_e;

  typedef struct {
    int               txn_id; // 事务 ID，用于复现
    string            txn_name; // 用例名
    logic [31:0]      txn_addr; // 本次地址
    logic [127:0]     txn_data; // 本次数据
    logic [15:0]      txn_strb; // 字节选通，用于写事务
    test_result_e     txn_result; // 结果
    string            txn_reason; // 失败原因
  } txn_result_e;

  typedef enum logic [1:0] {
    OKAY,
    RSV,
    SLVERR,
    DECERR
  } axil_resp_e;

  class axil_monitor#(
    parameter int ADDR_W = 32 ,
    parameter int DATA_W = 128 ,
    parameter int ID_W   = 4
  );
    // ------------------------------- Definiiton of enum -------------------------------
    typedef enum logic [1:0] {
      NORMAL,
      HIGH_IMPEDANCE,
      UNKNOWN_X
    } mnt_sig_state_e;

    typedef enum logic [1:0] {
      IDLE,
      WAIT_VALID,
      WAIT_READY,
      TRANSFER
    } mnt_trade_state_e;

    // ------------------------------- monitor virtual interface -------------------------------
    virtual if_axil_aw #(ADDR_W).MONITOR vif_mnt_axil_aw; // aw channel
    virtual if_axil_ar #(ADDR_W).MONITOR vif_mnt_axil_ar; // ar channel
    virtual if_axil_dw #(DATA_W).MONITOR vif_mnt_axil_dw; // dw channel
    virtual if_axil_dr #(DATA_W, ID_W).MONITOR vif_mnt_axil_dr; // dr channel
    virtual if_axil_wb #(ID_W).MONITOR vif_mnt_axil_wb; // wb channel

    // ------------------------------- config functions -------------------------------
    function mnt_axil_aw_new(virtual if_axil_aw #(ADDR_W).MONITOR vif_mnt_axil_aw);
        this.vif_mnt_axil_aw = vif_mnt_axil_aw;
    endfunction
    function mnt_axil_ar_new(virtual if_axil_ar #(ADDR_W).MONITOR vif_mnt_axil_ar);
        this.vif_mnt_axil_ar = vif_mnt_axil_ar;
    endfunction
    function mnt_axil_dw_new(virtual if_axil_dw #(DATA_W).MONITOR vif_mnt_axil_dw);
        this.vif_mnt_axil_dw = vif_mnt_axil_dw;
    endfunction
    function mnt_axil_dr_new(virtual if_axil_dr #(DATA_W, ID_W).MONITOR vif_mnt_axil_dr);
        this.vif_mnt_axil_dr = vif_mnt_axil_dr;
    endfunction
    function mnt_axil_wb_new(virtual if_axil_wb #(ID_W).MONITOR vif_mnt_axil_wb);
        this.vif_mnt_axil_wb = vif_mnt_axil_wb;
    endfunction
  endclass

  class axil_slave#(
    parameter int ADDR_W = 32 ,
    parameter int DATA_W = 128 ,
    parameter int ID_W   = 4
  );
    // ------------------------------- slave virtual interface -------------------------------
    virtual if_axil_aw #(ADDR_W).SLAVE vif_slv_axil_aw; // aw channel
    virtual if_axil_ar #(ADDR_W).SLAVE vif_slv_axil_ar; // ar channel
    virtual if_axil_dw #(DATA_W).SLAVE vif_slv_axil_dw; // dw channel
    virtual if_axil_dr #(DATA_W, ID_W).SLAVE vif_slv_axil_dr; // dr channel
    virtual if_axil_wb #(ID_W).SLAVE vif_slv_axil_wb; // wb channel

    // ------------------------------- config functions -------------------------------
    function slv_axil_aw_new(virtual if_axil_aw #(ADDR_W).SLAVE vif_slv_axil_aw);
        this.vif_slv_axil_aw = vif_slv_axil_aw;
    endfunction
    function slv_axil_ar_new(virtual if_axil_ar #(ADDR_W).SLAVE vif_slv_axil_ar);
        this.vif_slv_axil_ar = vif_slv_axil_ar;
    endfunction
    function slv_axil_dw_new(virtual if_axil_dw #(DATA_W).SLAVE vif_slv_axil_dw);
        this.vif_slv_axil_dw = vif_slv_axil_dw;
    endfunction
    function slv_axil_dr_new(virtual if_axil_dr #(DATA_W, ID_W).SLAVE vif_slv_axil_dr);
        this.vif_slv_axil_dr = vif_slv_axil_dr;
    endfunction
    function slv_axil_wb_new(virtual if_axil_wb #(ID_W).SLAVE vif_slv_axil_wb);
        this.vif_slv_axil_wb = vif_slv_axil_wb;
    endfunction

      task automatic slv_write_respond(
        input int task_id,
        input string task_name,
        input int max_timeout_cycle,
        input bit reset_assert,
        input axil_resp_e resp_assert,
        output txn_result_e result
      );
        string err_msg;
        axil_resp_e b_resp = OKAY;
        bit txn_done;
        bit aw_done;
        bit dw_done;
        logic [ADDR_W-1:0] rcv_addr;
        logic [DATA_W-1:0] rcv_data;
        result.txn_id = task_id;
        result.txn_name = task_name;
        result.txn_result = PASS;
        result.txn_reason = "";
        //reset all 
        if(reset_assert) begin
          vif_slv_axil_aw.rst = 1'b1;
          vif_slv_axil_dw.rst = 1'b1;
          vif_slv_axil_wb.rst = 1'b1;
          repeat(10) @(vif_slv_axil_aw.cb);
          vif_slv_axil_aw.rst = 1'b0;
          vif_slv_axil_dw.rst = 1'b0;
          vif_slv_axil_wb.rst = 1'b0;
        end
        fork : slv_write_respond_fork
          begin : aw_rcv
            @(vif_slv_axil_aw.cb);
            vif_slv_axil_aw.awready <= 1'b1; //从机可接收地址
            wait (vif_slv_axil_aw.awvalid && vif_slv_axil_aw.awready) begin
            rcv_addr = vif_slv_axil_aw.awaddr;
            aw_done = 1'b1;
            end
            vif_slv_axil_aw.awready <= 1'b0;
            wait (txn_done); //事务结束前不退出本分支
          end
          begin : dw_rcv
            @(vif_slv_axil_dw.cb);
            vif_slv_axil_dw.wready <= 1'b1; //从机可接收数据
            wait (vif_slv_axil_dw.wvalid && vif_slv_axil_dw.wready) begin
            rcv_data = vif_slv_axil_dw.wdata;
            dw_done = 1'b1;
            end
            vif_slv_axil_dw.wready <= 1'b0;
            wait (txn_done); //事务结束前不退出本分支
          end
          begin : wb_send
            wait (aw_done && dw_done); //AW和W都接收完成后才回BVALID
            @(vif_slv_axil_wb.cb);
            vif_slv_axil_wb.bvalid <= 1'b1;
            vif_slv_axil_wb.bresp <= resp_assert;
            wait (vif_slv_axil_wb.bvalid && vif_slv_axil_wb.bready) begin
            vif_slv_axil_wb.bvalid <= 1'b0;
            end
            txn_done = 1'b1; //B握手完成，事务结束
          end
          begin : timeout_monitor
            repeat(max_timeout_cycle) @(vif_slv_axil_aw.cb);
            if (!txn_done) begin
              err_msg = $sformatf("@%0t [TIMEOUT] slave write task %0d timeout for %0d cycles",$time,task_id,max_timeout_cycle);
              result.txn_reason = err_msg;
              result.txn_result = TIMEOUT;
              $error("%s",err_msg);
              txn_done = 1'b1;
            end
          end
        join_any
        disable slv_write_respond_fork; //事务完成或超时，回收所有线程
        result.txn_addr = rcv_addr; //记录接收到的地址
        result.txn_data = rcv_data; //记录接收到的数据
        if(result.txn_result == TIMEOUT) begin
            return;
        end
        else if(b_resp != OKAY) begin
          result.txn_result = FAIL;
          result.txn_reason = b_resp.name();
          return;
        end
        else begin
          result.txn_result = PASS;
          result.txn_reason = b_resp.name();
          return;
        end
      endtask 

      task automatic slv_read_respond(
        input int task_id,
        input string task_name,
        input int max_timeout_cycle,
        input bit reset_assert,
        input logic [DATA_W-1:0] rdata,
        output txn_result_e result
      );
        string err_msg;
        axil_resp_e r_resp = OKAY;
        bit txn_done;
        bit ar_done;
        logic [ADDR_W-1:0] rcv_addr;
        result.txn_id = task_id;
        result.txn_name = task_name;
        result.txn_result = PASS;
        result.txn_reason = "";
        //reset all 
        if(reset_assert) begin
          vif_slv_axil_ar.rst = 1'b1;
          vif_slv_axil_dr.rst = 1'b1;
          repeat(10) @(vif_slv_axil_ar.cb);
          vif_slv_axil_ar.rst = 1'b0;
          vif_slv_axil_dr.rst = 1'b0;
        end
        fork : slv_read_respond_fork
          begin : ar_rcv
            @(vif_slv_axil_ar.cb);
            vif_slv_axil_ar.arready <= 1'b1; //从机可接收地址
            wait (vif_slv_axil_ar.arvalid && vif_slv_axil_ar.arready) begin
            rcv_addr = vif_slv_axil_ar.araddr;
            ar_done = 1'b1;
            end
            vif_slv_axil_ar.arready <= 1'b0;
            wait (txn_done); //事务结束前不退出本分支
          end
          begin : r_send
            wait (ar_done); //AR握手完成后才回RVALID
            @(vif_slv_axil_dr.cb);
            vif_slv_axil_dr.rvalid <= 1'b1;
            vif_slv_axil_dr.rdata <= rdata;
            vif_slv_axil_dr.rresp <= OKAY;
            wait (vif_slv_axil_dr.rvalid && vif_slv_axil_dr.rready) begin
            vif_slv_axil_dr.rvalid <= 1'b0;
            end
            txn_done = 1'b1; //R握手完成，事务结束
          end
          begin : timeout_monitor
            repeat(max_timeout_cycle) @(vif_slv_axil_ar.cb);
            if (!txn_done) begin
              err_msg = $sformatf("@%0t [TIMEOUT] slave read task %0d timeout for %0d cycles",$time,task_id,max_timeout_cycle);
              result.txn_reason = err_msg;
              result.txn_result = TIMEOUT;
              $error("%s",err_msg);
              txn_done = 1'b1;
            end
          end
        join_any
        disable slv_read_respond_fork; //事务完成或超时，回收所有线程
        result.txn_addr = rcv_addr; //记录接收到的地址
        result.txn_data = rdata; //记录读出的数据
        if(result.txn_result == TIMEOUT) begin
            return;
        end
        else if(r_resp != OKAY) begin
          result.txn_result = FAIL;
          result.txn_reason = r_resp.name();
          return;
        end
        else begin
          result.txn_result = PASS;
          result.txn_reason = r_resp.name();
          return;
        end
      endtask 
  endclass
  
  class axil_driver#(
    parameter int ADDR_W = 32 ,
    parameter int DATA_W = 128 ,
    parameter int ID_W   = 4
    );
      // ------------------------------- axil_aw -------------------------------
      virtual if_axil_aw #(ADDR_W).MASTER vif_mst_axil_aw; // master
      // ------------------------------- axil_ar -------------------------------
      virtual if_axil_ar #(ADDR_W).MASTER vif_mst_axil_ar; // master
      // ------------------------------- axil_dw -------------------------------
      virtual if_axil_dw #(DATA_W).MASTER vif_mst_axil_dw; // master
      // ------------------------------- axil_dr -------------------------------
      virtual if_axil_dr #(DATA_W, ID_W).MASTER vif_mst_axil_dr; // master
      // ------------------------------- axil_wb -------------------------------
      virtual if_axil_wb #(ID_W).MASTER vif_mst_axil_wb; // master

      // ------------------------------- axil_aw -------------------------------
      function mst_axil_aw_new(virtual if_axil_aw #(ADDR_W).MASTER vif_mst_axil_aw);
          this.vif_mst_axil_aw = vif_mst_axil_aw;
      endfunction
      // ------------------------------- axil_ar -------------------------------
      function mst_axil_ar_new(virtual if_axil_ar #(ADDR_W).MASTER vif_mst_axil_ar);
          this.vif_mst_axil_ar = vif_mst_axil_ar;
      endfunction
      // ------------------------------- axil_dw -------------------------------
      function mst_axil_dw_new(virtual if_axil_dw #(DATA_W).MASTER vif_mst_axil_dw);
          this.vif_mst_axil_dw = vif_mst_axil_dw;
      endfunction
      // ------------------------------- axil_dr -------------------------------
      function mst_axil_dr_new(virtual if_axil_dr #(DATA_W, ID_W).MASTER vif_mst_axil_dr);
          this.vif_mst_axil_dr = vif_mst_axil_dr;
      endfunction
      // ------------------------------- axil_wb -------------------------------
      function mst_axil_wb_new(virtual if_axil_wb #(ID_W).MASTER vif_mst_axil_wb);
          this.vif_mst_axil_wb = vif_mst_axil_wb;
      endfunction
      
      task automatic mst_wr_reg(
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
        axil_resp_e wb_result;
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
        disable mst_write_reg_fork; //事务完成或超时，回收所有线程
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

      task automatic mst_rd_reg(
        input int task_id,
        input string task_name,
        input int max_timeout_cycle,
        input bit reset_assert,
        input logic [ADDR_W-1:0] addr,
        output logic [DATA_W-1:0] rdata,
        output txn_result_e result
      );
        string err_msg;
        axil_resp_e r_result;
        bit txn_done;
        // initialization
        rdata = {DATA_W{1'b1}};
        result.txn_id = task_id;
        result.txn_name = task_name;
        result.txn_addr = addr;
        result.txn_result = PASS;
        result.txn_reason = "";
        //reset all 
        if(reset_assert) begin
          vif_mst_axil_ar.rst = 1'b1;
          vif_mst_axil_dr.rst = 1'b1;
          repeat(10) @(vif_mst_axil_ar.cb);
          vif_mst_axil_ar.rst = 1'b0;
          vif_mst_axil_dr.rst = 1'b0;
        end
        fork : mst_read_reg_fork
          begin : ar_test
            @(vif_mst_axil_ar.cb);
            vif_mst_axil_ar.arvalid <= 1'b1;
            vif_mst_axil_ar.araddr <= addr;
            wait (vif_mst_axil_ar.arvalid && vif_mst_axil_ar.arready) vif_mst_axil_ar.arvalid <= 1'b0;
            wait (txn_done); //事务结束前不退出本分支
          end
          begin : r_test
            @(vif_mst_axil_dr.cb);
            vif_mst_axil_dr.rready <= 1'b1; //事务一开始就使能，随时可收数据
            wait (vif_mst_axil_dr.rvalid && vif_mst_axil_dr.rready) begin
            rdata = vif_mst_axil_dr.rdata;
            r_result = vif_mst_axil_dr.rresp;
            vif_mst_axil_dr.rready <= 1'b0;
            end
            txn_done = 1'b1; //R握手完成，事务结束
          end
          begin : timeout_monitor
            repeat(max_timeout_cycle) @(vif_mst_axil_ar.cb);
            if (!txn_done) begin
              err_msg = $sformatf("@%0t [TIMEOUT] task %0d timeout for %0d cycles",$time,task_id,max_timeout_cycle);
              result.txn_reason = err_msg;
              result.txn_result = TIMEOUT;
              $error("%s",err_msg);
              txn_done = 1'b1;
            end
          end
        join_any
        disable mst_read_reg_fork; //事务完成或超时，回收所有线程
        result.txn_data = rdata; //记录读回的数据
        if(result.txn_result == TIMEOUT) begin
            return;
        end
        else if(r_result != OKAY) begin
          result.txn_result = FAIL;
          result.txn_reason = r_result.name();
          return;
        end
        else begin
          result.txn_result = PASS;
          result.txn_reason = r_result.name();
          return;
        end
      endtask 
  endclass
endpackage
