cd vendor/llama.cpp && cmake --build build-static --config Release -j"$(sysctl -n hw.ncpu)" -t llama-server
