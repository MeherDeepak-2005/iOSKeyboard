#pragma once
#include "SpatialModel.hpp"
#include <array>
#include <span>
#include <string>
#include <vector>
namespace kb {
using TouchStatistics = std::array<double,5>; // count, mean x/y, M2 x/y
TouchStatistics observeTouch(TouchStatistics state,TouchOffset tap);
TouchOffset adjustTouch(const TouchStatistics& state,TouchOffset tap);
std::array<double,3> observeGlide(std::array<double,3> state,double cost);
std::array<double,2> glideParameters(std::array<double,3> state);
std::vector<double> characterPriors(std::span<const double> frequencies);
std::vector<double> contextualPriors(std::span<const std::string> letters,std::span<const std::string> baseLetters,std::span<const double> base);
}
