// Independent CPU ray intersection worker. All coordinates are double precision.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <numeric>
#include <stdexcept>
#include <thread>
#include <vector>

struct V {
    double x,y,z;
    V operator+(V b) const {return {x+b.x,y+b.y,z+b.z};}
    V operator-(V b) const {return {x-b.x,y-b.y,z-b.z};}
    V operator*(double a) const {return {x*a,y*a,z*a};}
    double at(int a) const {return a==0?x:a==1?y:z;}
};
double dot(V a,V b){return a.x*b.x+a.y*b.y+a.z*b.z;}
V cross(V a,V b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
struct Triangle { V a,b,c; V center()const{return (a+b+c)*(1.0/3);} };
struct Box {
    V lo{INFINITY,INFINITY,INFINITY}, hi{-INFINITY,-INFINITY,-INFINITY};
    void add(V p){lo={std::min(lo.x,p.x),std::min(lo.y,p.y),std::min(lo.z,p.z)};hi={std::max(hi.x,p.x),std::max(hi.y,p.y),std::max(hi.z,p.z)};}
    bool hit(V o,V d,double limit)const {
        double first=0,last=limit;
        for(int i=0;i<3;++i){
            double v=d.at(i),p=o.at(i),a=lo.at(i)-1e-9,b=hi.at(i)+1e-9;
            if(std::abs(v)<1e-20){if(p<a||p>b)return false;continue;}
            double t1=(a-p)/v,t2=(b-p)/v;if(t1>t2)std::swap(t1,t2);
            first=std::max(first,t1);last=std::min(last,t2);if(last<first)return false;
        }return true;
    }
};
struct Node {Box box;uint32_t begin=0,end=0;int left=-1,right=-1;};
class Scene {
    std::vector<Triangle> triangles;
    std::vector<uint32_t> order;
    std::vector<Node> nodes;
    int build(uint32_t a,uint32_t b){
        int id=static_cast<int>(nodes.size());nodes.push_back({});
        Box box,centers;for(uint32_t i=a;i<b;++i){auto&t=triangles[order[i]];box.add(t.a);box.add(t.b);box.add(t.c);centers.add(t.center());}
        nodes[id].box=box;nodes[id].begin=a;nodes[id].end=b;
        if(b-a<=8)return id;
        V span=centers.hi-centers.lo;int axis=span.x>span.y?0:1;if(span.z>span.at(axis))axis=2;
        uint32_t mid=a+(b-a)/2;
        std::nth_element(order.begin()+a,order.begin()+mid,order.begin()+b,[&](uint32_t x,uint32_t y){return triangles[x].center().at(axis)<triangles[y].center().at(axis);});
        int l=build(a,mid),r=build(mid,b);nodes[id].left=l;nodes[id].right=r;return id;
    }
    void visit(int id,V o,V d,double &nearest)const {
        const Node&n=nodes[id];if(!n.box.hit(o,d,nearest))return;
        if(n.left>=0){visit(n.left,o,d,nearest);visit(n.right,o,d,nearest);return;}
        for(uint32_t i=n.begin;i<n.end;++i){
            const auto&t=triangles[order[i]];V e1=t.b-t.a,e2=t.c-t.a,p=cross(d,e2);
            double det=dot(e1,p),scale=std::sqrt(dot(e1,e1)*dot(e2,e2));
            if(std::abs(det)<=1e-14*scale)continue;
            V s=o-t.a;double u=dot(s,p)/det;if(u< -1e-12||u>1+1e-12)continue;
            V q=cross(s,e1);double v=dot(d,q)/det;if(v< -1e-12||u+v>1+1e-12)continue;
            double distance=dot(e2,q)/det;if(distance>1e-7&&distance<nearest)nearest=distance;
        }
    }
public:
    explicit Scene(std::vector<Triangle> t):triangles(std::move(t)),order(triangles.size()) {
        std::iota(order.begin(),order.end(),0);if(!order.empty())build(0,static_cast<uint32_t>(order.size()));
    }
    double trace(V o,V d)const {double best=INFINITY;if(!nodes.empty())visit(0,o,d,best);return std::isfinite(best)?best:-1;}
};
template<class T>T read(std::istream& f){T value{};if(!f.read(reinterpret_cast<char*>(&value),sizeof(value)))throw std::runtime_error("Truncated input");return value;}
V vector(std::istream& f){V v=read<V>(f);if(!std::isfinite(v.x)||!std::isfinite(v.y)||!std::isfinite(v.z))throw std::runtime_error("Non-finite coordinate");return v;}
int wmain(int argc,wchar_t**argv){
    try {
        if(argc!=3)throw std::runtime_error("Usage: cj_engine input.bin output.bin");
        std::ifstream input(std::filesystem::path(argv[1]),std::ios::binary);
        char magic[8];if(!input.read(magic,8)||std::string(magic,8)!="CJIN0001")throw std::runtime_error("Invalid protocol");
        uint32_t nt=read<uint32_t>(input),np=read<uint32_t>(input),nd=read<uint32_t>(input);
        if(nt>10000000||np>1000000||nd>100000||nd==0||np==0||uint64_t(np)*nd>100000000)throw std::runtime_error("Invalid counts");
        auto expected=uint64_t(20)+uint64_t(nt)*72+(uint64_t(np)+nd)*24;
        if(std::filesystem::file_size(std::filesystem::path(argv[1]))!=expected)throw std::runtime_error("Invalid input size");
        std::vector<Triangle> triangles;triangles.reserve(nt);
        for(uint32_t i=0;i<nt;++i)triangles.push_back({vector(input),vector(input),vector(input)});
        std::vector<V> points,directions;
        for(uint32_t i=0;i<np;++i)points.push_back(vector(input));
        for(uint32_t i=0;i<nd;++i){V d=vector(input);double n=std::sqrt(dot(d,d));if(n<1e-15)throw std::runtime_error("Zero direction");directions.push_back(d*(1/n));}
        Scene scene(std::move(triangles));size_t count=size_t(np)*nd;
        std::vector<double> distances(count);std::atomic<size_t> cursor{0};
        unsigned workers=std::max(1u,std::min(16u,std::thread::hardware_concurrency()));
        std::vector<std::thread> threads;
        for(unsigned i=0;i<workers;++i)threads.emplace_back([&]{for(;;){size_t a=cursor.fetch_add(64);if(a>=count)break;for(size_t j=a;j<std::min(a+64,count);++j)distances[j]=scene.trace(points[j/nd],directions[j%nd]);}});
        for(auto& t:threads)t.join();
        std::ofstream output(std::filesystem::path(argv[2]),std::ios::binary);
        output.write("CJOUT001",8);output.write(reinterpret_cast<char*>(&np),4);output.write(reinterpret_cast<char*>(&nd),4);
        output.write(reinterpret_cast<char*>(distances.data()),static_cast<std::streamsize>(count*sizeof(double)));
        if(!output)throw std::runtime_error("Cannot write output");return 0;
    }catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 2;}
}
