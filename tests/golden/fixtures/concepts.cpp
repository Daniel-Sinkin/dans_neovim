namespace dans::test
{
template <typename V>
concept StringLike = std::convertible_to<V, std::string_view>;
template <typename R>
concept StringRange = input_range<R> and StringLike<ValueOf<R>>;
template <typename T>
concept IsInt = std::same_as<T, int>;
template <typename F>
concept Callback = invocable<F, int>;
template <typename T>
concept CharCol = CharLike<RefOf<T>>;
template <typename T>
concept BoolCol = BoolLike<T> and IntLike<T>;
template <typename I>
concept ItChar = std::same_as<iter_value_t<I>, char>;
template <typename R>
concept RefBool = convertible_to<range_reference_t<R>, bool>;
template <typename Proj, typename R>
concept Proj1 = std::convertible_to<std::invoke_result_t<Proj&, RefOf<R>>, std::string_view>;
template <typename R>
concept FormattableRange = input_range<R> and not StringRange<R> and CharLike<ValueOf<R>>;

static_assert(std::same_as<ValueOf<R>, char>);
static_assert(std::same_as<std::underlying_type_t<VkResult>, int>);
}  // namespace dans::test
