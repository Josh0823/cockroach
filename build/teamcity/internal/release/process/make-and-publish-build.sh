#!/usr/bin/env bash

set -euo pipefail

dir="$(dirname $(dirname $(dirname $(dirname $(dirname "${0}")))))"
source "$dir/release/teamcity-support.sh"
source "$dir/teamcity-bazel-support.sh"  # for run_bazel

tc_start_block "Variable Setup"

build_name=$(git describe --tags --dirty --match=v[0-9]* 2> /dev/null || git rev-parse --short HEAD;)

# On no match, `grep -Eo` returns 1. `|| echo""` makes the script not error.
release_branch="$(echo "$build_name" | grep -Eo "^v[0-9]+\.[0-9]+" || echo"")"
is_custom_build="$(echo "$TC_BUILD_BRANCH" | grep -Eo "^custombuild-" || echo "")"

if [[ -z "${DRY_RUN}" ]] ; then
  bucket="${BUCKET-cockroach-builds}"
  google_credentials=$GOOGLE_COCKROACH_CLOUD_IMAGES_COCKROACHDB_CREDENTIALS
  gcr_repository="us-docker.pkg.dev/cockroach-cloud-images/cockroachdb/cockroach"
  # Used for docker login for gcloud
  gcr_hostname="us-docker.pkg.dev"
else
  bucket="${BUCKET:-cockroach-builds-test}"
  google_credentials="$GOOGLE_COCKROACH_RELEASE_CREDENTIALS"
  gcr_repository="us.gcr.io/cockroach-release/cockroach-test"
  build_name="${build_name}.dryrun"
  gcr_hostname="us.gcr.io"
fi

cat << EOF

  build_name:      $build_name
  release_branch:  $release_branch
  is_custom_build: $is_custom_build
  bucket:          $bucket
  gcr_repository:  $gcr_repository

EOF
tc_end_block "Variable Setup"


tc_start_block "Tag the release"
git tag "${build_name}"
tc_end_block "Tag the release"

tc_start_block "Compile and publish S3 artifacts"
BAZEL_SUPPORT_EXTRA_DOCKER_ARGS="-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e TC_BUILD_BRANCH=$build_name -e bucket=$bucket" run_bazel << 'EOF'
bazel build --config ci //pkg/cmd/publish-provisional-artifacts
BAZEL_BIN=$(bazel info bazel-bin --config ci)
$BAZEL_BIN/pkg/cmd/publish-provisional-artifacts/publish-provisional-artifacts_/publish-provisional-artifacts -provisional -release -bucket "$bucket"
EOF
tc_end_block "Compile and publish S3 artifacts"

tc_start_block "Make and push docker image"
configure_docker_creds
docker_login_with_google

# TODO: update publish-provisional-artifacts with option to leave one or more cockroach binaries in the local filesystem
# NB: tar usually stops reading as soon as it sees an empty block but that makes
# curl unhappy, so passing `i` will cause it to read to the end.
curl -f -s -S -o- "https://${bucket}.s3.amazonaws.com/cockroach-${build_name}.linux-amd64.tgz" | tar ixfz - --strip-components 1
cp cockroach lib/libgeos.so lib/libgeos_c.so build/deploy
cp -r licenses build/deploy/

docker build --no-cache --tag="${gcr_repository}:${build_name}" build/deploy
docker push "${gcr_repository}:${build_name}"
tc_end_block "Make and push docker image"

tc_start_block "Push release tag to github.com/cockroachdb/cockroach"
github_ssh_key="${GITHUB_COCKROACH_TEAMCITY_PRIVATE_SSH_KEY}"
configure_git_ssh_key
git_wrapped push ssh://git@github.com/cockroachlabs/release-staging.git "${build_name}"
tc_end_block "Push release tag to github.com/cockroachdb/cockroach"


tc_start_block "Tag docker image as latest-build"
# Only tag the image as "latest-vX.Y-build" if the tag is on a release branch
# (or master for the alphas for the next major release).
if [[ -n "${release_branch}" ]] ; then
  log_into_gcloud
  gcloud container images add-tag "${gcr_repository}:${build_name}" "${gcr_repository}:latest-${release_branch}-build"
fi
tc_end_block "Tag docker image as latest-build"


# Make finding the tag name easy.
cat << EOF


Build ID: ${build_name}


EOF


if [[ -n "${is_custom_build}" ]] ; then
  tc_start_block "Delete custombuild tag"
  git_wrapped push ssh://git@github.com/cockroachdb/cockroach.git --delete "${TC_BUILD_BRANCH}"
  tc_end_block "Delete custombuild tag"
fi
