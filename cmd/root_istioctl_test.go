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

type IstioctlTestSuit struct {
	suite.Suite
	IstioctlPath string
}

func (suite *IstioctlTestSuit) SetupTest() {
	suite.IstioctlPath = istioctlPath
}

func TestCallIstio(t *testing.T) {
	output := callIstioctl()
	assert.NotEqual(t, "", output)
}

func (suite *IstioctlTestSuit) TestCallIstioWithAbsentIstioPanics() {
	istioctlPath = "/tmp/notIstioByAnyMeans"

	assert.Panics(suite.T(), func() { callIstioctl() })
	istioctlPath = suite.IstioctlPath
}

func TestCallIstioVersion(t *testing.T) {
	expected := `Version: 0.2.4
GitRevision: 9c7c291eab0a522f8033decd0f5b031f5ed0e126
GitBranch: master
User: root@822a7ac3ca86
GolangVersion: go1.8.3` + "\n\n"

	output := callIstioctl("version")

	assert.Equal(t, expected, output)
}

func TestCallIstioGetRouterulesReturnsNonEmpty(t *testing.T) {
	output := callIstioctl("get routerules -o yaml")
	assert.NotEqual(t, "", output)
}
