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
    logic [2:0] axif_awport;
    
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
    logic [2:0] axif_arport;
    
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
