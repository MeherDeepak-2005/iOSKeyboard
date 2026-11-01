// tools/evaluation/autocorrect/IOSBench.cpp compiled into the test bundle, so DeviceBenchmark.swift
// replays the same corpora and writes the same JSONL on a phone as evaluate.py does on a Mac.
#define main kbIOSBenchMain
#include "../tools/evaluation/autocorrect/IOSBench.cpp"
#undef main

extern "C" int kb_ios_bench(int argc, char** argv) { return kbIOSBenchMain(argc, argv); }
