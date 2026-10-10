// OWNER: AI-03
//
// Minimal self-contained test harness for the shim host tests. BUILD_PLAN AI-03 suggests vendoring
// GoogleTest or Catch2; this round downloads nothing, so the tests use this ~150-line harness instead
// (same shape: TEST(suite, name), EXPECT_* continue, ASSERT_* return, SKIP(reason)).
//
//   vw_tests                 run everything
//   vw_tests <substring>...  run tests whose "suite.name" contains any substring
//   vw_tests --list          list test names
#ifndef VW_TEST_H
#define VW_TEST_H

#include <cstdio>
#include <cstring>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

namespace vwt {

struct TestCase {
  const char *suite;
  const char *name;
  std::function<void()> fn;
};

inline std::vector<TestCase> &registry() {
  static std::vector<TestCase> r;
  return r;
}

struct Registrar {
  Registrar(const char *suite, const char *name, std::function<void()> fn) {
    registry().push_back({suite, name, std::move(fn)});
  }
};

struct State {
  int failures = 0;        // failures in the current test
  bool skipped = false;
  std::string skip_reason;
};

inline State &state() {
  static State s;
  return s;
}

struct SkipException {};
struct AssertException {};

inline void report_failure(const char *file, int line, const std::string &msg) {
  ++state().failures;
  std::fprintf(stderr, "  FAILED %s:%d: %s\n", file, line, msg.c_str());
}

template <typename A, typename B>
std::string describe(const char *ea, const char *eb, const A &a, const B &b, const char *op) {
  std::ostringstream os;
  os << ea << " " << op << " " << eb << " (" << a << " vs " << b << ")";
  return os.str();
}

int run_all(int argc, char **argv);

}  // namespace vwt

#define VWT_CAT2(a, b) a##b
#define VWT_CAT(a, b) VWT_CAT2(a, b)

#define TEST(suite, name)                                                                         \
  static void VWT_CAT(vwt_test_, VWT_CAT(suite, VWT_CAT(_, name)))();                              \
  static ::vwt::Registrar VWT_CAT(vwt_reg_, VWT_CAT(suite, VWT_CAT(_, name)))(                     \
      #suite, #name, &VWT_CAT(vwt_test_, VWT_CAT(suite, VWT_CAT(_, name))));                       \
  static void VWT_CAT(vwt_test_, VWT_CAT(suite, VWT_CAT(_, name)))()

#define VWT_CHECK(cond, fatal, msg)                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      ::vwt::report_failure(__FILE__, __LINE__, (msg));                   \
      if (fatal) throw ::vwt::AssertException();                          \
    }                                                                     \
  } while (0)

#define EXPECT_TRUE(c) VWT_CHECK((c), false, std::string("expected true: ") + #c)
#define EXPECT_FALSE(c) VWT_CHECK(!(c), false, std::string("expected false: ") + #c)
#define ASSERT_TRUE(c) VWT_CHECK((c), true, std::string("expected true: ") + #c)
#define ASSERT_FALSE(c) VWT_CHECK(!(c), true, std::string("expected false: ") + #c)

#define VWT_CMP(a, b, op, fatal)                                                              \
  do {                                                                                        \
    const auto vwt_a = (a); /* copies: (b) may be a reference to a temporary (std::min) */    \
    const auto vwt_b = (b);                                                                   \
    if (!(vwt_a op vwt_b)) {                                                                  \
      ::vwt::report_failure(__FILE__, __LINE__, ::vwt::describe(#a, #b, vwt_a, vwt_b, #op));  \
      if (fatal) throw ::vwt::AssertException();                                              \
    }                                                                                         \
  } while (0)

#define EXPECT_EQ(a, b) VWT_CMP(a, b, ==, false)
#define EXPECT_NE(a, b) VWT_CMP(a, b, !=, false)
#define EXPECT_LT(a, b) VWT_CMP(a, b, <, false)
#define EXPECT_LE(a, b) VWT_CMP(a, b, <=, false)
#define EXPECT_GT(a, b) VWT_CMP(a, b, >, false)
#define EXPECT_GE(a, b) VWT_CMP(a, b, >=, false)
#define ASSERT_EQ(a, b) VWT_CMP(a, b, ==, true)
#define ASSERT_NE(a, b) VWT_CMP(a, b, !=, true)
#define ASSERT_LT(a, b) VWT_CMP(a, b, <, true)
#define ASSERT_LE(a, b) VWT_CMP(a, b, <=, true)
#define ASSERT_GT(a, b) VWT_CMP(a, b, >, true)
#define ASSERT_GE(a, b) VWT_CMP(a, b, >=, true)

#define SKIP(reason)                       \
  do {                                     \
    ::vwt::state().skipped = true;         \
    ::vwt::state().skip_reason = (reason); \
    throw ::vwt::SkipException();          \
  } while (0)

#endif  // VW_TEST_H
