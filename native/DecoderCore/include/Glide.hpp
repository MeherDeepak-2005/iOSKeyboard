#pragma once
#include "CandidateGeneration.hpp"
#include "LanguageModel.hpp"
#include "Ranking.hpp"
namespace kb {
struct Point { double x = 0, y = 0; };
struct GlideLayout { std::vector<std::pair<std::uint8_t, Point>> centers; double xPitch, yPitch; };
struct ProcessedGlide { std::vector<Point> points; std::vector<std::size_t> pivots; std::vector<std::uint8_t> dwell; };
Point toGrid(Point point, const GlideLayout& layout);
std::vector<Point> resample(std::span<const Point> points, double spacing);
std::vector<std::size_t> pivots(std::span<const Point> points, double threshold = 0.5);
std::vector<std::uint8_t> lettersNear(Point point, double radius, std::size_t maxCount);
std::optional<std::uint8_t> nearestLetter(Point point);
std::optional<ProcessedGlide> preprocess(std::span<const Point> points, const GlideLayout& layout,
    double spacing, std::span<const double> times);
std::vector<Point> resampleN(std::span<const Point> points, std::size_t count);
std::optional<std::vector<Point>> idealPath(std::string_view word, std::size_t count);
std::optional<double> shapeCost(std::string_view word, std::span<const Point> observed, int band, double direction);
std::vector<ChannelCandidate> decodeGlide(std::span<const Point> observed, const PackedLexicon& lexicon,
    std::size_t width, int band, double frequency, double direction, double seedRadius, std::size_t window,
    const std::function<bool()>& cancel);
class GlideResampler {
    double spacing_, distance_ = 0;
    std::optional<Point> last_;
public:
    std::vector<Point> samples;
    explicit GlideResampler(double spacing) : spacing_(spacing) {}
    std::vector<Point> append(std::span<const Point> points);
};
class OnlineGlide {
    std::vector<double> previous_;
public:
    std::vector<Point> ideal;
    std::size_t sampleCount = 0;
    explicit OnlineGlide(std::vector<Point> path);
    void consume(std::span<const Point> points);
    double prefixCost() const;
};
} // namespace kb

namespace kb {
class StreamingGlide final {
    GlideResampler resampler_{0.5};
    std::size_t rawCount_ = 0;
    std::optional<std::pair<double, double>> pitch_;
    std::vector<std::uint8_t> first_, last_, previousFirst_, previousLast_;
    std::vector<std::pair<std::string, OnlineGlide>> candidates_;
    std::unordered_set<std::string> words_;
public:
    bool invalid = false, needsAugmentation = false;
    bool empty() const { return candidates_.empty(); }
    bool consume(std::span<const Point> raw, const GlideLayout& layout);
    void augment(const GenerationLexicon& lexicon, std::span<const std::string> contextWords, std::span<const std::string> dynamicWords);
    std::vector<ChannelCandidate> rows() const;
};
std::vector<ChannelCandidate> augmentGlide(const GenerationLexicon& lexicon, std::vector<ChannelCandidate> beam,
    std::span<const Point> points, std::span<const std::string> contextWords,
    std::span<const std::string> dynamicWords, double gate, const std::function<bool()>& cancel);
std::vector<RankedRow> rankGlide(const GenerationLexicon& lexicon, std::span<const ChannelCandidate> rows,
    std::span<const double> language, std::span<const double> safety, double sigma, std::span<const std::uint8_t> dwell);
std::vector<std::string> dynamicGlideWords(const CountRows& supplementary, const CountRows& personal, std::size_t limit);
} // namespace kb
