import configparser
import subprocess
import os
run_number = os.getenv('GITHUB_RUN_NUMBER', '0')
build_location = os.getenv('BUILD_LOCATION', 'local')


def trackerReleaseVersion(prefsLoc):
    projectDir = os.path.abspath(os.path.dirname(prefsLoc) or ".")
    repoRoot = os.path.abspath(os.path.join(projectDir, os.pardir, os.pardir))
    helperPath = os.path.join(projectDir, os.pardir, "release_identity.py")
    if not os.path.isfile(helperPath):
        if os.getenv("TRACKER_RELEASE") or os.getenv("TRACKER_SOURCE_SHA"):
            raise RuntimeError("tracker release helper is missing: {}".format(helperPath))
        return None
    # Execute the tracked source explicitly. Normal import loaders may accept a valid ignored
    # __pycache__/release_identity*.pyc before the source attestor has had a chance to reject
    # executable caches.
    helperScope = {
        "__file__": helperPath,
        "__name__": "tracker_release_identity",
    }
    with open(helperPath, "rb") as helperFile:
        exec(compile(helperFile.read(), helperPath, "exec"), helperScope)
    return helperScope["tracker_release_version"](repoRoot, build_root=projectDir)


def readProps(prefsLoc):
    """Read the version of our project as a string"""

    config = configparser.RawConfigParser()
    config.read(prefsLoc)
    version = dict(config.items("VERSION"))
    verObj = dict(
        short="{}.{}.{}".format(version["major"], version["minor"], version["build"]),
        long="unset",
        deb="unset",
    )

    # Try to find current build SHA if if the workspace is clean.  This could fail if git is not installed
    try:
        sha = (
            subprocess.check_output(["git", "rev-parse", "--short", "HEAD"])
            .decode("utf-8")
            .strip()
        )
        isDirty = (
            subprocess.check_output(["git", "diff", "HEAD"]).decode("utf-8").strip()
        )
        suffix = sha
        # if isDirty:
        #     # short for 'dirty', we want to keep our verstrings source for protobuf reasons
        #     suffix = sha + "-d"
        verObj["long"] = "{}.{}".format(verObj["short"], suffix)
        verObj["deb"] = "{}.{}~{}{}".format(verObj["short"], run_number, build_location, sha)
    except:
        # print("Unexpected error:", sys.exc_info()[0])
        # traceback.print_exc()
        verObj["long"] = verObj["short"]
        verObj["deb"] = "{}.{}~{}".format(verObj["short"], run_number, build_location)

    releaseVersion = trackerReleaseVersion(prefsLoc)
    if releaseVersion:
        verObj["long"] = releaseVersion

    # print("firmware version " + verStr)
    return verObj


# print("path is" + ','.join(sys.path))
