#include <gtest/gtest.h>

extern "C" {
#include "classifier.h"
}

TEST(Classifier, Smoke) { EXPECT_TRUE(true); }
TEST(Classifier, PositivePrimary) { EXPECT_STREQ("positive", classify(5)); }
TEST(Classifier, PositiveDuplicate) { EXPECT_STREQ("positive", classify(5)); }
TEST(Classifier, High) { EXPECT_STREQ("high", classify(11)); }
TEST(Classifier, Nonpositive) { EXPECT_STREQ("nonpositive", classify(0)); }
