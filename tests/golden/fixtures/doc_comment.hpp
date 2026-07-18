/// # Format helper
/// renders `T` through `to_string`, returns a std::string
/// - free `to_string(const T&)` preferred
/// - member `T.to_string()` fallback
///
/// ```cpp
/// DANS_FORMAT_WITH_TO_STRING(demo::Meta)
/// std::println("{}", meta);
/// ```
struct Helper
{
    int value{};
};

// an ordinary comment is left alone, not rendered as markdown
struct Plain
{
    int n{};
};
