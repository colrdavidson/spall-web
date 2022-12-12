clang -shared -fpic -O3 instrument.c -o instrument.so
clang -ldl -lpthread -finstrument-functions -rdynamic -O3 sample_program.c ./instrument.so -o instrument_test
