// OWNER: AI-03
//
// Minimal self-contained test harness for the shim host tests. BUILD_PLAN AI-03 suggests vendoring
// GoogleTest or Catch2; this round downloads nothing, so the tests use this ~150-line harness instead
// (same shape: TEST(suite, name), EXPECT_* continue, ASSERT_* return, SKIP(reason)).
//
//   dv_tests                 run everything
//   dv_tests <substring>...  run tests whose "suite.name" contains any substring
//   dv_tests --list          list test names
#ifndef DV_TEST_H
#define DV_TEST_H

#include <cstdio>
#include <cstring>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

namespace dvt {

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

}  // namespace dvt

#define DVT_CAT2(a, b) a##b
#define DVT_CAT(a, b) DVT_CAT2(a, b)

#define TEST(suite, name)                                                                         \
  static void DVT_CAT(dvt_test_, DVT_CAT(suite, DVT_CAT(_, name)))();                              \
  static ::dvt::Registrar DVT_CAT(dvt_reg_, DVT_CAT(suite, DVT_CAT(_, name)))(                     \
      #suite, #name, &DVT_CAT(dvt_test_, DVT_CAT(suite, DVT_CAT(_, name))));                       \
  static void DVT_CAT(dvt_test_, DVT_CAT(suite, DVT_CAT(_, name)))()

#define DVT_CHECK(cond, fatal, msg)                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      ::dvt::report_failure(__FILE__, __LINE__, (msg));                   \
      if (fatal) throw ::dvt::AssertException();                          \
    }                                                                     \
  } while (0)

#define EXPECT_TRUE(c) DVT_CHECK((c), false, std::string("expected true: ") + #c)
#define EXPECT_FALSE(c) DVT_CHECK(!(c), false, std::string("expected false: ") + #c)
#define ASSERT_TRUE(c) DVT_CHECK((c), true, std::string("expected true: ") + #c)
#define ASSERT_FALSE(c) DVT_CHECK(!(c), true, std::string("expected false: ") + #c)

#define DVT_CMP(a, b, op, fatal)                                                              \
  do {                                                                                        \
    const auto dvt_a = (a); /* copies: (b) may be a reference to a temporary (std::min) */    \
    const auto dvt_b = (b);                                                                   \
    if (!(dvt_a op dvt_b)) {                                                                  \
      ::dvt::report_failure(__FILE__, __LINE__, ::dvt::describe(#a, #b, dvt_a, dvt_b, #op));  \
      if (fatal) throw ::dvt::AssertException();                                              \
    }                                                                                         \
  } while (0)

#define EXPECT_EQ(a, b) DVT_CMP(a, b, ==, false)
#define EXPECT_NE(a, b) DVT_CMP(a, b, !=, false)
#define EXPECT_LT(a, b) DVT_CMP(a, b, <, false)
#define EXPECT_LE(a, b) DVT_CMP(a, b, <=, false)
#define EXPECT_GT(a, b) DVT_CMP(a, b, >, false)
#define EXPECT_GE(a, b) DVT_CMP(a, b, >=, false)
#define ASSERT_EQ(a, b) DVT_CMP(a, b, ==, true)
#define ASSERT_NE(a, b) DVT_CMP(a, b, !=, true)
#define ASSERT_LT(a, b) DVT_CMP(a, b, <, true)
#define ASSERT_LE(a, b) DVT_CMP(a, b, <=, true)
#define ASSERT_GT(a, b) DVT_CMP(a, b, >, true)
#define ASSERT_GE(a, b) DVT_CMP(a, b, >=, true)

#define SKIP(reason)                       \
  do {                                     \
    ::dvt::state().skipped = true;         \
    ::dvt::state().skip_reason = (reason); \
    throw ::dvt::SkipException();          \
  } while (0)

#endif  // DV_TEST_H
