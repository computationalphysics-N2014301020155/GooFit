set -evx
cd "${DEPS_DIR}"
mkdir -p extrabin
cd extrabin

if [ "$CXX" = "g++" ] ; then
    ln -s `which gcc-$COMPILER` gcc
    ln -s `which g++-$COMPILER` g++
    ln -s `which gcov-$COMPILER` gcov
else
    ln -s `which clang-$COMPILER` clang
    ln -s `which clang++-$COMPILER` clang++
    ln -s `which clang-format-$COMPILER` clang-format
    ln -s `which clang-tidy-$COMPILER` clang-tidy
    export CXXFLAGS="-stdlib=libc++"
fi

export PATH="${DEPS_DIR}/extrabin":$PATH

cd "${TRAVIS_BUILD_DIR}"
set +evx
