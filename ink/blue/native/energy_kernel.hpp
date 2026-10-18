// 蓝墨数值推进内核：不依赖物理插件，不接触 Godot 对象，只处理本地像素/焦耳。
// 所有更新同步写入 next；工作量由活跃波头及局部分叉决定，不建电网或搜索路径。
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <stdexcept>

namespace blue {
using Key = uint64_t;
inline Key key(int x,int y){ return (uint64_t(uint32_t(x))<<32)|uint32_t(y); }
inline int xof(Key p){return int32_t(p>>32);}
inline int yof(Key p){return int32_t(p);}
static constexpr int dx[4]={-1,1,0,0}, dy[4]={0,0,-1,1};
inline Key near(Key p,int d){return key(xof(p)+dx[d],yof(p)+dy[d]);}
struct Head {
    std::array<double,4> e{};
    int64_t expiry=0,wave=0,group=0;
    int64_t producer=0;
    int64_t normalise_stamp=0; // 当前波头上的临时洪泛标记，不参与保存/能源规则。
    uint8_t yielded=0; // 本子步被更强对向分量取代的方向；供胜者通过相遇位置。
    bool biological=false;
    bool ring_entry=false; // 虚拟滑环口无来路方向；离开接收格后恢复普通有向规则。
    double total()const{return e[0]+e[1]+e[2]+e[3];}
    void scale(double f){for(auto &v:e)v*=f;}
};
using Front=std::unordered_map<Key,Head>;
struct Target {int wire;Key cell;int dir;};
struct Wire {
    std::unordered_set<Key> mask;
    Front front,next;
    std::unordered_map<Key,int64_t> tail;
    std::unordered_map<Key,std::array<int64_t,4>> visited;
    std::unordered_map<Key,std::vector<int>> sinks;
    std::unordered_map<Key,Target> bridges;
    std::vector<int> neighbours;
    double px=0,py=0,angle=0;
    int64_t injection_tick=-1,injection_group=0;
};
struct Reader {
    const uint8_t *data;size_t size,pos=0;
    template<class T>T read(){if(pos+sizeof(T)>size)throw std::runtime_error("short input");T v;std::memcpy(&v,data+pos,sizeof(T));pos+=sizeof(T);return v;}
};
struct Writer {
    uint8_t *data;size_t size,pos=0;
    template<class T>void put(T v){if(pos+sizeof(T)>size)throw std::runtime_error("output capacity");std::memcpy(data+pos,&v,sizeof(T));pos+=sizeof(T);}
};
struct Kernel {
    std::unordered_map<int,Wire> wires;
    int64_t clock=0,serial=0,updates=0;
    int64_t normalise_serial=0;
    double injected=0,consumed=0,lost=0,capacity=1e7,minimum=1,opposition_recovery=0;
    int64_t life=12000;
    std::vector<double> rooms,delivered;
    std::vector<double> delivered_bio;
    int64_t biological_producer=0;
    std::unordered_set<int64_t> seeds;
    std::unordered_map<int64_t,int64_t> junctions;
    std::unordered_map<int64_t,double> blocked;

    void inject(int id,Key p,int dir,double energy,int64_t producer){
        auto &w=wires.at(id);if(!w.mask.count(p)||energy<=0)return;
        if(w.injection_tick!=clock){w.injection_tick=clock;w.injection_group=++serial;seeds.insert(serial);}
        auto it=w.front.find(p);
        if(it==w.front.end()){Head h;h.expiry=clock+life;h.wave=clock+1;h.group=w.injection_group;h.producer=producer;it=w.front.emplace(p,h).first;}
        else if(it->second.producer!=producer)it->second.producer=0;
        it->second.biological=it->second.biological||(producer!=0&&producer==biological_producer);
        if(dir<0){it->second.ring_entry=true;dir=0;}
        it->second.e.at(dir)+=energy;injected+=energy;
    }
    // 比较相遇位置的有向能量；相等时使用固定方向/载体 ID 决胜。
    // 先仅标记败者，比较时都读同一份 front，避免哈希迭代顺序影响结果。
    static void oppose(Head &a,int da,Head &b,int db,bool tie_a){
        if(a.ring_entry||b.ring_entry||a.e[da]<=0||b.e[db]<=0)return;
        if(a.e[da]>b.e[db]||(a.e[da]==b.e[db]&&tie_a))b.yielded|=uint8_t(1<<db);
        else a.yielded|=uint8_t(1<<da);
    }
    void resolve_opposition(){
        for(auto &[id,w]:wires)for(auto &[p,h]:w.front){
            h.yielded=0;
            if(h.ring_entry)continue;
            for(int d=0;d<4;d+=2)if(h.e[d]>0&&h.e[d+1]>0){
                int winner=h.e[d]>h.e[d+1]?d:d+1; // 等值保留右/下方向。
                int loser=winner^1;
                double transfer=h.e[loser]*opposition_recovery;
                h.e[winner]+=transfer;
                lost+=h.e[loser]-transfer;
                h.e[loser]=0;h.yielded|=uint8_t(1<<loser);
            }
        }
        for(auto &[id,w]:wires)for(auto &[p,h]:w.front)if(!h.ring_entry){
            for(int d=0;d<4;d++)if(h.e[d]>0){
                auto other=w.front.find(near(p,d));
                if(other!=w.front.end()){
                    if(d&1)oppose(h,d,other->second,d^1,true);
                }else if(!w.mask.count(near(p,d))&&!w.neighbours.empty())foreign(id,w,p,d,h,true);
            }
        }
        for(auto &[id,w]:wires)for(auto &[p,h]:w.front)for(int d=0;d<4;d++)if(h.yielded&(1<<d)){
            lost+=h.e[d];h.e[d]=0;
        }
    }
    // 只协调同一相连波头。出口分开后分配新组号，不把远处独立支路重新混在一起。
    void normalise(Front &f,bool seed){
        if(seed?seeds.empty():junctions.empty())return;
        // 复用波头自身的标记做局部洪泛，避免每次推进都为每格分配哈希集合节点。
        const int64_t stamp=++normalise_serial;
        std::unordered_map<int64_t,std::vector<Key>> groups;
        for(auto &[p,h]:f)if(seed?seeds.count(h.group):junctions.count(h.group))groups[h.group].push_back(p);
        for(auto &[gid,todo]:groups){
            std::vector<std::vector<Key>> parts;std::vector<double> sums;
            double total=seed?0:blocked[gid];
            for(Key start:todo){
                if(f.at(start).normalise_stamp==stamp)continue;
                std::vector<Key> q{start};f.at(start).normalise_stamp=stamp;double amount=0;
                for(size_t i=0;i<q.size();i++){
                    Key p=q[i];amount+=f.at(p).total();
                    for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++){
                        if(x==0&&y==0)continue;
                        Key n=key(xof(p)+x,yof(p)+y);auto next=f.find(n);
                        if(next!=f.end()&&next->second.group==gid&&next->second.normalise_stamp!=stamp){next->second.normalise_stamp=stamp;q.push_back(n);}
                    }
                }
                parts.push_back(std::move(q));sums.push_back(amount);total+=amount;
            }
            if(!seed)blocked.erase(gid);
            for(size_t i=0;i<parts.size();i++){
                int64_t id=parts.size()>1?++serial:gid;
                if(parts.size()>1&&!seed)junctions[id]=clock+2;
                double target=total/parts.size();
                if(!seed&&target<minimum){lost+=target;for(Key p:parts[i])f.erase(p);continue;}
                double scale=seed?1:target/std::max(sums[i],1e-30);
                for(Key p:parts[i]){f.at(p).scale(scale);f.at(p).group=id;}
            }
        }
    }
    void consume_front(Wire &w){
        if(w.sinks.empty())return;
        struct Group{std::vector<Key> cells;std::vector<int> motors;double energy=0;bool biological=false;};
        std::unordered_map<int64_t,Group> groups;
        for(auto &[p,h]:w.front){
            if(!w.mask.count(p)||h.total()<=0)continue;
            auto it=w.sinks.find(p);if(it==w.sinks.end())continue;
            auto &g=groups[h.group];
            for(int m:it->second)if(std::find(g.motors.begin(),g.motors.end(),m)==g.motors.end())g.motors.push_back(m);
        }
        if(groups.empty())return;
        for(auto &[p,h]:w.front){auto it=groups.find(h.group);if(it!=groups.end()){it->second.cells.push_back(p);it->second.energy+=h.total();it->second.biological=it->second.biological||h.biological;}}
        for(auto &[id,g]:groups){
            double remaining=g.energy;
            std::sort(g.motors.begin(),g.motors.end());
            for(int m:g.motors)if(m>=0&&size_t(m)<rooms.size()){
                double take=std::min(std::max(0.,rooms[m]),remaining);rooms[m]-=take;delivered[m]+=take;consumed+=take;remaining-=take;
                if(g.biological)delivered_bio[m]+=take;
            }
            double scale=remaining/std::max(g.energy,1e-30);
            for(Key p:g.cells)w.front.at(p).scale(scale);
        }
    }
    static void add(Front &f,Key p,int d,double energy,const Head &from){
        auto it=f.find(p);
        if(it==f.end()){Head h;h.expiry=from.expiry;h.wave=from.wave;h.group=from.group;h.producer=from.producer;it=f.emplace(p,h).first;}
        else if(it->second.producer!=from.producer)it->second.producer=0;
        it->second.biological=it->second.biological||from.biological;
        if(d<0){it->second.ring_entry=true;d=0;}
        it->second.e[d]+=energy;it->second.expiry=std::min(it->second.expiry,from.expiry);
    }
    Target foreign(int id,Wire &w,Key p,int d,Head &head,bool resolve=false){
        double c=std::cos(w.angle),s=std::sin(w.angle);
        double lx=xof(p)+dx[d]+0.5,ly=yof(p)+dy[d]+0.5;
        double wx=w.px+lx*c-ly*s,wy=w.py+lx*s+ly*c;
        for(int oid:w.neighbours){
            auto it=wires.find(oid);if(it==wires.end())continue;auto &o=it->second;
            double oc=std::cos(o.angle),os=std::sin(o.angle),ox=wx-o.px,oy=wy-o.py;
            Key at=key(int(std::floor(ox*oc+oy*os)),int(std::floor(-ox*os+oy*oc)));
            if(!o.mask.count(at))continue;
            double angle=w.angle-o.angle,rx=dx[d]*std::cos(angle)-dy[d]*std::sin(angle),ry=dx[d]*std::sin(angle)+dy[d]*std::cos(angle);
            int nd=std::abs(rx)>=std::abs(ry)?(rx>=0?1:0):(ry>=0?3:2);
            auto f=o.front.find(at);
            if(resolve){if(f!=o.front.end())oppose(head,d,f->second,nd^1,id<oid);continue;}
            bool yielded=f!=o.front.end()&&(f->second.yielded&(1<<(nd^1)));
            auto seen=o.visited.find(at);
            if(!yielded&&((seen!=o.visited.end()&&seen->second[nd]>=head.wave)||(f!=o.front.end()&&f->second.total()>0)))continue;
            return {oid,at,nd};
        }
        return {-1,0,0};
    }
    void step(){
        clock++;blocked.clear();
        resolve_opposition();
        // 保留双缓冲桶容量，避免每个像素步都为整批波头重新扩容哈希表。
        for(auto &[id,w]:wires){w.next.clear();if(w.next.bucket_count()<w.front.size())w.next.reserve(w.front.size()*2+8);}
        for(auto &[id,w]:wires){
            // 按来向记访问：胜者可以穿过败者的反向足迹，回到自己的同向足迹仍会停止。
            for(auto &[p,h]:w.front)if(h.total()>0){auto &seen=w.visited[p];for(int d=0;d<4;d++)if(h.ring_entry||h.e[d]>0)seen[d]=std::max(seen[d],h.wave);}
            for(auto it=w.tail.begin();it!=w.tail.end();)if(it->second<=clock)it=w.tail.erase(it);else ++it;
            consume_front(w);
            auto &out=w.next;updates+=w.front.size();
            for(auto &[p,h]:w.front){
                double amount=h.total();
                if(!w.mask.count(p)||h.expiry<=clock||amount<=0){lost+=amount;continue;}
                if(amount>capacity){lost+=amount-capacity;amount=capacity;}
                std::array<Target,5> exits{};int count=0;
                for(int d=0;d<4;d++){
                    if(!h.ring_entry&&h.e[d^1]>0)continue;
                    Key at=near(p,d);auto seen=w.visited.find(at);
                    if(w.mask.count(at)){
                        auto f=w.front.find(at);
                        bool yielded=f!=w.front.end()&&(f->second.yielded&(1<<(d^1)));
                        if(yielded||((f==w.front.end()||f->second.total()<=0)&&(seen==w.visited.end()||seen->second[d]<h.wave)))exits[count++]={id,at,d};
                    }else if(!w.neighbours.empty()){
                        Target t=foreign(id,w,p,d,h);if(t.wire>=0)exits[count++]=t;
                    }
                }
                {
                    auto b=w.bridges.find(p);
                    if(b!=w.bridges.end()){
                        auto &o=wires.at(b->second.wire);auto seen=o.visited.find(b->second.cell);
                        if(o.mask.count(b->second.cell)&&!o.front.count(b->second.cell)&&(seen==o.visited.end()||*std::max_element(seen->second.begin(),seen->second.end())<h.wave)){
                            // 滑环也是分叉出口，导线不必在轴处结束；转轴两侧局部坐标可不同。
                            exits[count++]={b->second.wire,b->second.cell,-1};
                        }
                    }
                }
                if(!count){blocked[h.group]+=amount;junctions[h.group]=clock+2;}
                else {
                    if(count>1)junctions[h.group]=clock+2;
                    for(int i=0;i<count;i++)add(exits[i].wire==id?out:wires.at(exits[i].wire).next,exits[i].cell,exits[i].dir,amount/count,h);
                }
                w.tail[p]=clock+3;
            }
        }
        for(auto &[id,w]:wires){normalise(w.next,false);w.front.swap(w.next);}
        for(auto &[gid,e]:blocked)lost+=e;
        for(auto it=junctions.begin();it!=junctions.end();)if(it->second<clock)it=junctions.erase(it);else ++it;
    }
    double stored()const{double e=0;for(auto &[id,w]:wires)for(auto &[p,h]:w.front)e+=h.total();return e;}
    void write_snapshot(Writer &o){
        // 大缓冲区会触发 PackedByteArray 写时复制。容量按本次活跃数据增长，
        // 不按整张蓝线面积分配；不足时仅重取快照，绝不重复推进/扣费。
        size_t needed=68+delivered.size()*16;
        for(auto &[id,w]:wires)needed+=24+w.front.size()*12+w.tail.size()*8;
        if(needed>o.size){o.put<int32_t>(-int32_t(needed));return;}
        o.put<int32_t>(0);o.put<int64_t>(clock);
        o.put<double>(injected);o.put<double>(consumed);o.put<double>(lost);o.put<double>(stored());
        o.put<int64_t>(updates);o.put<int64_t>(0); // 保留旧 shorts 统计槽；不再自动短路。
        o.put<int32_t>(int(delivered.size()));for(size_t i=0;i<delivered.size();i++){o.put<double>(delivered[i]);o.put<double>(delivered_bio[i]);}
        o.put<int32_t>(int(wires.size()));
        for(auto &[id,w]:wires){
            o.put<int32_t>(id);o.put<int32_t>(int(w.front.size()));
            for(auto &[p,h]:w.front){o.put<float>(float(xof(p)));o.put<float>(float(yof(p)));}
            for(auto &[p,h]:w.front)o.put<float>(float(h.total()));
            o.put<int32_t>(int(w.tail.size()));for(auto &[p,t]:w.tail){o.put<float>(float(xof(p)));o.put<float>(float(yof(p)));}
            o.put<int32_t>(0);o.put<int32_t>(0); // 兼容显示协议的删除/闪点空槽。
        }
    }
    void command(const uint8_t *input,size_t length,uint8_t *output,size_t cap,size_t &written){
        Reader r{input,length};Writer o{output,cap};bool snapshot=false;
        try{
            while(r.pos<r.size){int op=r.read<int32_t>();
                if(op==1){int id=r.read<int32_t>(),n=r.read<int32_t>();auto &w=wires[id];w.mask.clear();for(int i=0;i<n;i++){float x=r.read<float>(),y=r.read<float>();w.mask.insert(key(int(x),int(y)));}}
                else if(op==2){int id=r.read<int32_t>();auto &w=wires[id];w.px=r.read<double>();w.py=r.read<double>();w.angle=r.read<double>();}
                else if(op==3){int id=r.read<int32_t>(),x=r.read<int32_t>(),y=r.read<int32_t>(),d=r.read<int32_t>();double e=r.read<double>();int64_t producer=r.read<int64_t>();inject(id,key(x,y),d,e,producer);}
                else if(op==4){for(auto &[id,w]:wires){w.sinks.clear();w.bridges.clear();w.neighbours.clear();}}
                else if(op==5){int id=r.read<int32_t>(),x=r.read<int32_t>(),y=r.read<int32_t>(),m=r.read<int32_t>();wires.at(id).sinks[key(x,y)].push_back(m);}
                else if(op==6){int id=r.read<int32_t>(),x=r.read<int32_t>(),y=r.read<int32_t>(),other=r.read<int32_t>(),ox=r.read<int32_t>(),oy=r.read<int32_t>();wires.at(id).bridges[key(x,y)]={other,key(ox,oy),0};}
                else if(op==7){int id=r.read<int32_t>(),n=r.read<int32_t>();auto &v=wires.at(id).neighbours;v.clear();for(int i=0;i<n;i++)v.push_back(r.read<int32_t>());}
                else if(op==9){int id=r.read<int32_t>();for(auto &[p,h]:wires.at(id).front)lost+=h.total();wires.erase(id);}
                else if(op==10){
                    int steps=r.read<int32_t>(),n=r.read<int32_t>();rooms.resize(n);delivered.assign(n,0);delivered_bio.assign(n,0);for(auto &v:rooms)v=r.read<double>();
                    for(auto &[id,w]:wires)normalise(w.front,true);seeds.clear();
                    for(int i=0;i<steps;i++)step();write_snapshot(o);snapshot=true;
                }
                else if(op==11){capacity=r.read<double>();life=r.read<int64_t>();minimum=r.read<double>();biological_producer=r.read<int64_t>();opposition_recovery=std::clamp(r.read<double>(),0.0,1.0);}
                else if(op==12){
                    int id=r.read<int32_t>();auto &w=wires.at(id);size_t needed=4+w.front.size()*80;
                    if(needed>o.size)o.put<int32_t>(-int32_t(needed));
                    else {o.put<int32_t>(int(w.front.size()));for(auto &[p,h]:w.front){o.put<int32_t>(xof(p));o.put<int32_t>(yof(p));for(double e:h.e)o.put<double>(e);o.put<int64_t>(h.expiry);o.put<int64_t>(h.wave);o.put<int64_t>(h.group);o.put<int32_t>(h.ring_entry);o.put<int64_t>(h.producer);o.put<int32_t>(h.biological);}}
                    snapshot=true;
                }
                else if(op==13){write_snapshot(o);snapshot=true;}
                else if(op==14){
                    int id=r.read<int32_t>(),x=r.read<int32_t>(),y=r.read<int32_t>(),d=r.read<int32_t>();double e=r.read<double>();
                    Head h;h.expiry=r.read<int64_t>();h.wave=r.read<int64_t>();h.group=r.read<int64_t>();h.ring_entry=r.read<int32_t>()!=0;h.producer=r.read<int64_t>();h.biological=r.read<int32_t>()!=0;
                    // 碎裂迁移不是生产：保留方向、年龄与波号，冲回旧载体退场时计入的损失。
                    if(wires.at(id).mask.count(key(x,y))&&e>0){add(wires.at(id).front,key(x,y),h.ring_entry?-1:d,e,h);lost-=e;}
                }
                else throw std::runtime_error("unknown command");
            }
            if(!snapshot)o.put<int32_t>(0);
        }catch(const std::exception &e){std::fprintf(stderr,"Energy command error: %s\n",e.what());o.pos=0;o.put<int32_t>(-1);}
        catch(...){std::fprintf(stderr,"Energy command error: unknown\n");o.pos=0;o.put<int32_t>(-1);}
        written=o.pos;
    }
};
} // namespace blue
