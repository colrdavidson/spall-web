clang -ldl -lpthread -finstrument-functions -rdynamic -O3 sample_program.c -o instrument_test
