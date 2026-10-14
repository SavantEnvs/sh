// Build-time switch: leak detection off for every target that links this TU (fleet policy).
extern "C" int __lsan_is_turned_off(void) { return 1; }
