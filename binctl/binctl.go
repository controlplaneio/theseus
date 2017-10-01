// Copyright © 2017 Control Plane <info@control-plane.io>
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package binctl

import (
	"os/exec"
	"regexp"
	"strings"

	"github.com/blang/semver"
	logging "github.com/op/go-logging"
)

var (
	istioctlPath = "istioctl"
	kubectlPath  = "kubectl"

	log = logging.MustGetLogger("example")
)

func CallIstioctl(command ...string) string {
	return callBinary(istioctlPath, command)
}

func CallKubectl(command ...string) string {
	return callBinary(kubectlPath, command)
}

func checkIsBinaryInPath(pathToBinary string) {
	_, lookErr := exec.LookPath(pathToBinary)
	if lookErr != nil {
		panic(lookErr)
	}
}

func callBinary(binary string, command []string) string {
	if len(command) == 0 {
		command = []string{"version"}
	}
	checkIsBinaryInPath(binary)

	commandString := binary + " " + strings.Join(command[:], " ")
	log.Info("command string", commandString)
	shellCommand := exec.Command("bash", "-c", commandString)
	shellOutput, err := shellCommand.Output()
	if err != nil {
		panic(err)
	}
	return string(shellOutput)
}

func CheckKubectlVersion(requiredVersion string, version ...struct {
	Client string
	Server string
}) bool {

	var clientVersion semver.Version
	var serverVersion semver.Version

	if len(version) > 1 {
		panic("Only one version injection permitted")

	} else if len(version) == 1 {
		clientVersion = getSemver(version[0].Client)
		serverVersion = getSemver(version[0].Server)

	} else {
		versionOutput := CallKubectl("version")
		versionOutputLines := strings.Split(versionOutput, "\n")

		re := regexp.MustCompile(`.*GitVersion:"v([^"]*)".*`)

		gitVersionClient := re.ReplaceAllString(versionOutputLines[0], `$1`)
		gitVersionServer := re.ReplaceAllString(versionOutputLines[1], `$1`)
		clientVersion = getSemver(gitVersionClient)
		serverVersion = getSemver(gitVersionServer)
	}

	requiredVersionSemver := getSemver(requiredVersion)

	log.Info("client version kubectl", clientVersion)
	log.Info("server version kubectl", serverVersion)

	return clientVersion.GTE(requiredVersionSemver) && serverVersion.GTE(requiredVersionSemver)
}

func CheckIstioctlVersion(requiredVersion string, version ...struct {
	Client string
}) bool {

	var clientVersion semver.Version

	if len(version) > 1 {
		panic("Only one version injection permitted")

	} else if len(version) == 1 {
		clientVersion = getSemver(version[0].Client)

	} else {
		versionOutput := CallIstioctl("version")
		versionOutputLines := strings.Split(versionOutput, "\n")

		re := regexp.MustCompile(`^Version: (.*)`)

		gitVersionClient := re.ReplaceAllString(versionOutputLines[0], `$1`)
		clientVersion = getSemver(gitVersionClient)
	}

	requiredVersionSemver := getSemver(requiredVersion)

	log.Info("client version istioctl", clientVersion)

	return clientVersion.GTE(requiredVersionSemver)
}

func getSemver(providedVersion string) semver.Version {
	parsedVersion, err := semver.Make(providedVersion)
	if err != nil {
		log.Error("Validation failed for '%s': %s\n", providedVersion, err)
		panic(err)
	}
	return parsedVersion
}
