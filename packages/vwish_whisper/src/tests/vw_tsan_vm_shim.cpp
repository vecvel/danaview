// OWNER: AI-03
//
// ThreadSanitizer builds on macOS only (tests/CMakeLists.txt adds this file when VW_SANITIZER=thread and
// APPLE). ggml_aligned_malloc() uses vm_allocate()/vm_deallocate() on macOS, which TSan does not
// intercept: when one thread frees pages and another gets the same pages back (two models loading or
// two jobs allocating compute buffers), TSan sees unsynchronized writes to the same address and reports
// a false race. These definitions live in the test executable, so the statically linked ggml binds to
// them instead of libSystem's and the memory goes through the intercepted malloc/free. Nothing in the
// shipped library is affected (the iOS/Android builds never compile this file).
#include <mach/mach.h>

#include <cstdlib>
#include <cstring>

extern "C" kern_return_t vm_allocate(vm_map_t /*target_task*/, vm_address_t *address, vm_size_t size, int /*flags*/) {
  void *p = nullptr;
  if (size == 0) size = 1;
  if (posix_memalign(&p, 16384, size) != 0 || p == nullptr) return KERN_NO_SPACE;
  std::memset(p, 0, size);  // vm_allocate returns zero-filled pages
  *address = reinterpret_cast<vm_address_t>(p);
  return KERN_SUCCESS;
}

extern "C" kern_return_t vm_deallocate(vm_map_t /*target_task*/, vm_address_t address, vm_size_t /*size*/) {
  std::free(reinterpret_cast<void *>(address));
  return KERN_SUCCESS;
}
