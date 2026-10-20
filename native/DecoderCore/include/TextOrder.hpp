#pragma once
#include <algorithm>
#include <cstdint>
#include <string_view>
namespace kb {
inline bool utf8Less(std::string_view a, std::string_view b) {
    return std::lexicographical_compare(a.begin(), a.end(), b.begin(), b.end(), [](unsigned char x, unsigned char y) { return x < y; });
}
inline bool validUTF8(std::string_view text) {
    std::size_t i=0;
    while(i<text.size()) {
        auto c=static_cast<unsigned char>(text[i++]); if(c<128)continue;
        std::uint32_t value=0,minimum=0;std::size_t count=0;
        if(c>=0xc2&&c<=0xdf){value=c&31;minimum=0x80;count=1;}
        else if(c>=0xe0&&c<=0xef){value=c&15;minimum=0x800;count=2;}
        else if(c>=0xf0&&c<=0xf4){value=c&7;minimum=0x10000;count=3;}
        else return false;
        if(count>text.size()-i)return false;
        for(std::size_t j=0;j<count;++j){auto next=static_cast<unsigned char>(text[i++]);if((next&0xc0)!=0x80)return false;value=(value<<6)|(next&63);}
        if(value<minimum||value>0x10ffff||(value>=0xd800&&value<=0xdfff))return false;
    }return true;
}
}
