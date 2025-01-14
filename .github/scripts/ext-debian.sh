#!/bin/bash

set -e
set -o errexit
# Extension for Debian repo and pacakge support

#### Debian specific functions

# Update the changelog to specify the target distribution codename
update_changelog() {
  set -x
  cd "${PKG_BUILD_DIR:?}/$PACKAGE_NAME"
  version=$(dpkg-parsechangelog --show-field Version)
  dch --distribution "$CODENAME" --newversion "${version}-1regolith" "Automated release."

  cd - >/dev/null 2>&1 || exit
}

# Determine if the changelog has the correct distribution codename
dist_valid() {
  cd "${PKG_BUILD_DIR:?}/$PACKAGE_NAME"

  TOP_CHANGELOG_LINE=$(head -n 1 debian/changelog)
  CHANGELOG_DIST=$(echo "$TOP_CHANGELOG_LINE" | cut -d' ' -f3)

  cd - >/dev/null 2>&1
  # echo "Checking $CODENAME and $CHANGELOG_DIST"
  if [[ "$CHANGELOG_DIST" == *"$CODENAME"* ]]; then
    return 0
  else
    return 1
  fi
}

stage_source() {
  pushd .

  echo "Preparing source for $PACKAGE_NAME"
  cd "$PKG_BUILD_DIR/$PACKAGE_NAME" || exit
  debian_package_name=$(dpkg-parsechangelog --show-field Source)
  full_version=$(dpkg-parsechangelog --show-field Version)
  debian_version="${full_version%-*}"
  cd "$PKG_BUILD_DIR" || exit

  echo "Generating source tarball from git repo."
  tar cfzv --force-local $debian_package_name\_${debian_version}.orig.tar.gz --exclude .git\* --exclude /debian $PACKAGE_NAME/../$PACKAGE_NAME

  popd
}

build_src_package() {
  set -e

  pushd .
  echo "Building source package $PACKAGE_NAME"
  cd "$PKG_BUILD_DIR/$PACKAGE_NAME" || exit

  sanitize_git
  sudo apt build-dep -y .
  debuild -S -sa

  popd
}

build_bin_package() {
  set -e
  
  pushd .
  echo "Building binary package $PACKAGE_NAME"
  cd "$PKG_BUILD_DIR/$PACKAGE_NAME" || exit

  debuild -sa -b
  popd
}

# Internal (private) function
source_pkg_exists() {
    SRC_PKG_VERSION=$(reprepro --basedir "$PKG_REPO_PATH" list "$CODENAME" "$1" | cut -d' ' -f3)

    SRC_PKG_BUILD_VERSION=$(echo $2 | cut -d'-' -f1)
    SRC_PKG_REPO_VERSION=$(echo $SRC_PKG_VERSION | cut -d'-' -f1)

    if [ "$SRC_PKG_REPO_VERSION" == "$SRC_PKG_BUILD_VERSION" ]; then
        return 0
    else
        return 1
    fi
}

publish() {
  cd "${PKG_BUILD_DIR:?}/$PACKAGE_NAME"
  version=$(dpkg-parsechangelog --show-field Version)
  debian_package_name=$(dpkg-parsechangelog --show-field Source)
  cd "$PKG_BUILD_DIR"

  DEB_SRC_PKG_PATH="$PKG_BUILD_DIR/${debian_package_name}_${version}_source.changes"

  if [ ! -f "$DEB_SRC_PKG_PATH" ]; then
    echo "Failed to find changes file."
  fi

  if source_pkg_exists "$debian_package_name" "$version"; then
      echo "Ignoring source package, already exists in target repository"
      allow_failing_bin_package="true"
  else
      echo "Ingesting source package $debian_package_name into $PKG_REPO_PATH"
      reprepro --basedir "$PKG_REPO_PATH" include "$CODENAME" "$DEB_SRC_PKG_PATH"
      allow_failing_bin_package="false"
  fi

  DEB_CONTROL_FILE="$PKG_BUILD_DIR/$PACKAGE_NAME/debian/control"
  ALL_ARCH="$ARCH,all"

  for target_arch in $(echo $ALL_ARCH | sed "s/,/ /g"); do
      cat "$DEB_CONTROL_FILE" | grep ^Package: | cut -d' ' -f2 | while read -r bin_pkg; do
          DEB_BIN_PKG_PATH="$(pwd)/${bin_pkg}_${version}_${target_arch}.deb"
          if [ -f "$DEB_BIN_PKG_PATH" ]; then
              if [ "$allow_failing_bin_package" == "true" ]; then                
                # If the source package/version already exists, allow the bin package build to fail (already exists)
                reprepro --basedir "$PKG_REPO_PATH" includedeb "$CODENAME" "$DEB_BIN_PKG_PATH" || true
                echo "Ingested binary package $DEB_BIN_PKG_PATH into $PKG_REPO_PATH"
              else
                reprepro --basedir "$PKG_REPO_PATH" includedeb "$CODENAME" "$DEB_BIN_PKG_PATH"
                echo "Ingested binary package $DEB_BIN_PKG_PATH into $PKG_REPO_PATH"
              fi
              echo "CHLOG:Published ${bin_pkg}_${version}_${target_arch}.deb in $STAGE $DISTRO $CODENAME $ARCH from $PKG_LINE"
          else
              echo "Package $bin_pkg does not exist for $target_arch"
          fi
      done
  done
}

# Create repo dist file
generate_reprepro_dist() {
    echo "Origin: $PACKAGE_REPO_URL" > "$PKG_REPO_PATH/conf/distributions"
    echo "Label: $PACKAGE_REPO_URL" >> "$PKG_REPO_PATH/conf/distributions"
    echo "Codename: $CODENAME" >> "$PKG_REPO_PATH/conf/distributions"
    echo "Architectures: $ARCH source" >> "$PKG_REPO_PATH/conf/distributions"
    echo "Components: main" >> "$PKG_REPO_PATH/conf/distributions"
    echo "Description: $STAGE $DISTRO $CODENAME $ARCH" >> "$PKG_REPO_PATH/conf/distributions"
    echo "SignWith: $APT_KEY" >> "$PKG_REPO_PATH/conf/distributions"
}

# Setup debian repo
setup() {
  if [ ! -d "$PKG_REPO_PATH/conf" ]; then
    echo "Creating conf dir"
    mkdir -p "$PKG_REPO_PATH/conf"    
  fi

  if [ ! -f "$PKG_REPO_PATH/conf/distributions" ]; then
    echo "Package metadata not found, creating conf dir"
    generate_reprepro_dist
    cat "$PKG_REPO_PATH/conf/distributions"
  else
    echo "Existing metadata:"
    cat "$PKG_REPO_PATH/conf/distributions"
  fi

  source_setup_scripts
}
