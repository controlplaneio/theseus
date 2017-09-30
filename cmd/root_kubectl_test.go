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

package cmd

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/suite"
)

type KubectlTestSuite struct {
	suite.Suite
	KubectlPath string
}

func (suite *KubectlTestSuite) SetupTest() {
	suite.KubectlPath = kubectlPath
}

func TestCallKubectl(t *testing.T) {
	output := callKubectl()
	assert.NotEqual(t, "", output)
}

func (suite *KubectlTestSuite) TestCallKubectlWithAbsentKubectlPanics() {
	kubectlPath = "/tmp/notKubectlByAnyMeans"

	assert.Panics(suite.T(), func() { callKubectl() })
	kubectlPath = suite.KubectlPath
}

func TestCallKubectlVersion(t *testing.T) {
	expected := `Client Version: version.Info{Major:"1", Minor:"7", GitVersion:"v1.7.3", GitCommit:"2c2fe6e8278a5db2d15a013987b53968c743f2a1", GitTreeState:"clean", BuildDate:"2017-08-03T07:00:21Z", GoVersion:"go1.8.3", Compiler:"gc", Platform:"linux/amd64"}
Server Version: version.Info{Major:"1", Minor:"7+", GitVersion:"v1.7.5-gke.1", GitCommit:"2aa350cad8d86efa8c94811b70bd67646daf5772", GitTreeState:"clean", BuildDate:"2017-09-27T17:38:14Z", GoVersion:"go1.8.3", Compiler:"gc", Platform:"linux/amd64"}` + "\n"

	output := callKubectl("version")

	assert.Equal(t, expected, output)
}
