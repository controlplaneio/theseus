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
	"os"
	"os/exec"

	"strings"

	logging "github.com/op/go-logging"
)

var (
	istioctlPath = "istioctl"
	kubectlPath  = "kubectl"

	log = logging.MustGetLogger("example")
)

func setupLogging() {

	format := logging.MustStringFormatter(
		`%{color}%{time:15:04:05.000} %{shortfunc} ▶ %{level:.4s} %{id:03x}%{color:reset} %{message}`,
	)

	logBackend := logging.NewLogBackend(os.Stderr, "", 0)
	backendFormatter := logging.NewBackendFormatter(logBackend, format)
	backendLeveled := logging.AddModuleLevel(backendFormatter)

	//backendLeveled.SetLevel(logging.ERROR, "")
	backendLeveled.SetLevel(logging.INFO, "")

	logging.SetBackend(backendLeveled)
}

func callIstioctl(command ...string) string {
	return callBinary(istioctlPath, command)
}

func callKubectl(command ...string) string {
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
