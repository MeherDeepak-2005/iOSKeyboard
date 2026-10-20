#include "../include/Adaptation.hpp"
#include <algorithm>
#include <cmath>
#include <unordered_map>
namespace kb {
TouchStatistics observeTouch(TouchStatistics s,TouchOffset tap) {
    s[0]+=1;const double dx=tap.dx-s[1],dy=tap.dy-s[2];s[1]+=dx/s[0];s[2]+=dy/s[0];s[3]+=dx*(tap.dx-s[1]);s[4]+=dy*(tap.dy-s[2]);
    if(s[0]>2000){s[0]=std::floor(s[0]/2);s[3]*=.5;s[4]*=.5;}return s;
}
TouchOffset adjustTouch(const TouchStatistics& s,TouchOffset tap) {
    if(s[0]<32)return tap;const double denominator=std::max(1.,s[0]-1);
    return {(tap.dx-std::clamp(s[1],-.22,.22))*std::clamp(.28/std::sqrt(std::max(s[3]/denominator,.01)),.75,1.25),
            (tap.dy-std::clamp(s[2],-.22,.22))*std::clamp(.28/std::sqrt(std::max(s[4]/denominator,.01)),.75,1.25)};
}
std::array<double,3> observeGlide(std::array<double,3> s,double cost) {
    if(!std::isfinite(cost)||cost<0)return s;const auto old=s[1];s[1]=(1-.12)*s[1]+.12*cost;s[2]=(1-.12)*s[2]+.12*(cost-old)*(cost-s[1]);s[0]+=1;return s;
}
std::array<double,2> glideParameters(std::array<double,3> s) {
    const auto blend=std::min(1.,s[0]/12.);
    return {std::clamp(.10+((.10/.22)*s[1]-.10)*blend,.06,.30),
            std::clamp(.43+(s[1]+2.7*std::sqrt(std::max(0.,s[2]))-.43)*blend,.30,.60)};
}
std::vector<double> characterPriors(std::span<const double> frequencies) {
    std::vector<double> out(frequencies.size());if(frequencies.empty())return out;
    const double top=*std::max_element(frequencies.begin(),frequencies.end());if(top<=0)return out;
    const double denom=std::log(top+1);for(size_t i=0;i<out.size();++i)if(frequencies[i]>0)out[i]=std::log(frequencies[i]+1)/denom;return out;
}
std::vector<double> contextualPriors(std::span<const std::string> letters,std::span<const std::string> baseLetters,std::span<const double> base) {
    std::unordered_map<std::string,double> contextual;double weight=1,top=0;
    for(const auto& c:letters){contextual[c]+=weight;weight*=.85;top=std::max(top,contextual[c]);}
    std::vector<double> out;out.reserve(baseLetters.size());
    for(size_t i=0;i<baseLetters.size();++i)out.push_back(std::max(i<base.size()?base[i]:0.,top>0?contextual[baseLetters[i]]/top:0.));return out;
}
}
