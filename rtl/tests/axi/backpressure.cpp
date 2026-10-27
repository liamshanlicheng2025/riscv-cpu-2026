#include "Vstudent_top.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <deque>
#include <iostream>
#include <stdexcept>

static void require(bool ok, const char* reason) {
    if (!ok) throw std::runtime_error(reason);
}
struct Response { unsigned sequence; uint64_t due; };
struct Write { uint32_t data; unsigned mask; };

static void exercise(unsigned seed, unsigned latency) {
    Vstudent_top d;
    d.reset=1;
    for (int i=0;i<5;++i) { d.clock=0;d.eval();d.clock=1;d.eval(); }
    d.reset=0;
    uint32_t random=seed;
    auto next=[&]() { random^=random<<13;random^=random>>17;random^=random<<5;return random; };
    std::deque<unsigned> addresses;
    std::deque<Write> values;
    std::deque<Response> reads,writes;
    std::array<bool,301> seen{};
    bool held_ar=false,held_aw=false,held_w=false;
    uint32_t last_ar=0,last_aw=0,last_data=0;
    unsigned last_mask=0,completed=0,split=0;
    for (uint64_t cycle=0;cycle<100000;++cycle) {
        d.arready=reads.size()<16 && next()%5!=0;
        d.awready=addresses.size()+writes.size()<16 && next()%3!=0 && cycle>29;
        d.wready=values.size()+writes.size()<16 && next()%4!=0;
        d.rvalid=!reads.empty() && cycle>=reads.front().due;
        d.rdata=reads.empty()?0:0xa5a51234u^reads.front().sequence;
        d.rresp=reads.empty()?0:(reads.front().sequence%17==0?2:0);
        d.bvalid=!writes.empty() && cycle>=writes.front().due;
        d.bresp=writes.empty()?0:(writes.front().sequence%17==0?2:0);
        d.clock=0;d.eval();
        if (held_ar) require(d.arvalid && d.araddr==last_ar,"AR changed under backpressure");
        if (held_aw) require(d.awvalid && d.awaddr==last_aw,"AW changed under backpressure");
        if (held_w) require(d.wvalid && d.wdata==last_data && d.wstrb==last_mask,"W changed under backpressure");
        held_ar=d.arvalid && !d.arready;last_ar=d.araddr;
        held_aw=d.awvalid && !d.awready;last_aw=d.awaddr;
        held_w=d.wvalid && !d.wready;last_data=d.wdata;last_mask=d.wstrb;
        const bool ar=d.arvalid && d.arready,aw=d.awvalid && d.awready,w=d.wvalid && d.wready;
        const bool r=d.rvalid && d.rready,b=d.bvalid && d.bready;
        if (aw!=w) ++split;
        bool exit=false;
        if (r) { ++completed;reads.pop_front(); }
        if (b) {
            exit=writes.front().sequence==300;
            if (!exit) ++completed;
            writes.pop_front();
        }
        if (ar) {
            const unsigned n=(d.araddr-0x1000)/4;
            require(n<300 && n%3!=0 && !seen[n],"bad or duplicate AR");
            seen[n]=true;reads.push_back({n,cycle+latency+next()%7});
        }
        if (aw) {
            const unsigned n=d.awaddr==0x80000000u?300:(d.awaddr-0x1000)/4;
            require(n<=300 && n%3==0 && !seen[n],"bad or duplicate AW");
            seen[n]=true;addresses.push_back(n);
        }
        if (w) values.push_back({d.wdata,d.wstrb});
        if (!addresses.empty() && !values.empty()) {
            const unsigned n=addresses.front();
            require(values.front().data==(0xdeadbeefu^n) && values.front().mask==n%15+1,"AW/W paired incorrectly");
            writes.push_back({n,cycle+latency+next()%7});addresses.pop_front();values.pop_front();
        }
        d.clock=1;d.eval();
        if (exit) {
            require(completed==300 && reads.empty() && writes.empty() && addresses.empty() && values.empty(),"exit before drain");
            for (bool present:seen) require(present,"missing AXI request");
            require(split>20,"AW/W separation was not exercised");
            d.final();
            std::cout<<"PASS AXI seed="<<seed<<" latency="<<latency<<" split="<<split<<" cycles="<<cycle+1<<'\n';
            return;
        }
    }
    throw std::runtime_error("AXI watchdog");
}
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    try { for (unsigned l:{3,20,97}) for (unsigned s:{1,19,71,139}) exercise(s,l);return 0; }
    catch (const std::exception& e) { std::cerr<<e.what()<<'\n';return 1; }
}
