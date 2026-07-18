#pragma once

#include <core/log.hpp>
#include <util/id.hpp>

#if PROJECT_FEATURE
#include <ext/ext.hpp>
#endif

#ifdef WIDGET_EXTRA_HEADER
#include WIDGET_EXTRA_HEADER
#endif

namespace fixture::ui
{
struct Widget
{
    util::Id id{};
};
}
