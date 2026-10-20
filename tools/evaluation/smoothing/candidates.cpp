// Fixed, unfunded production channel search shared by both smoothing models.
#include "PackedLexicon.hpp"
#include "IncrementalSearch.hpp"
#include <fstream>
#include <iostream>
#include <iomanip>
#include <iterator>
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    std::ifstream input(argv[1], std::ios::binary);
    std::vector<char> bytes((std::istreambuf_iterator<char>(input)), {});
    kb::PackedLexicon lexicon(std::as_bytes(std::span(bytes)));
    std::string word;
    double radius;
    std::cout << std::setprecision(17);
    while (std::cin >> word >> radius) {
        const auto rows = lexicon.search(word, radius);
        std::cout << rows.size();
        for (const auto& row : rows)
            std::cout << '\t' << row.word << '\t' << row.cost << '\t' << row.logFrequency;
        std::cout << std::endl;
    }
}
