// constrained template params
template <std::convertible_to<bool> A, std::same_as<int> B>
void f();

template <std::convertible_to<bool> A>
concept Boolish = A;

template <typename T>
concept Convertible = true;

template <BoolLike A, std::convertible_to<bool> B>
void g();

template <BoolLike T, Convertible<T> S>
void h();
