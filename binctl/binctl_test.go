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
	"testing"

	"regexp"

	"fmt"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/suite"
)

type BinctlTestSuite struct {
	suite.Suite
	IstioctlPath string
	KubectlPath  string
}

// run suite tests
func TestBinctlParseTestSuite(t *testing.T) {
	suite.Run(t, new(BinctlTestSuite))
}

func (suite *BinctlTestSuite) SetupTest() {
	suite.IstioctlPath = istioctlPath
}

func TestCallIstio(t *testing.T) {
	output := CallIstioctl()
	assert.NotEqual(t, "", output)
}

func (suite *BinctlTestSuite) TestCallIstioWithAbsentIstioPanics() {
	istioctlPath = "/tmp/notIstioByAnyMeans"

	assert.Panics(suite.T(), func() { CallIstioctl() })
	istioctlPath = suite.IstioctlPath
}

func TestCallIstioVersion(t *testing.T) {
	expectedRegex := regexp.MustCompile("^Version: 0.2.4")

	output := CallIstioctl("version")

	assert.Regexp(t, expectedRegex, output)
}

func TestCallIstioGetRouterulesReturnsNonEmpty(t *testing.T) {
	output := CallIstioctl("get routerules -o yaml")
	assert.NotEqual(t, "", output)
}

func TestCallKubectlVersion(t *testing.T) {
	expectedRegex := regexp.MustCompile("^Client Version:.*\nServer Version:")

	output := CallKubectl("version")

	assert.Regexp(t, expectedRegex, output)
}

// ---

var kubectlVersionDataProvider = []struct {
	requiredVersion string
	clientVersion   string
	serverVersion   string
	expected        bool
}{
	{"1.1.0", "1.0.0", "1.0.0", false},
	{"1.6.0", "1.6.0", "1.7.0", true},
	{"1.7.0", "1.6.0", "1.7.0", false},
	{"1.7.0", "1.7.4", "1.8.1", true},
	{"2.1.1", "1.6.0", "1.7.0", false},
}

func (suite *BinctlTestSuite) TestCheckKubectlVersion() {
	for _, data := range kubectlVersionDataProvider {

		versions := struct {
			Client string
			Server string
		}{data.clientVersion, data.serverVersion}

		assert.Equal(suite.T(),
			CheckKubectlVersion(data.requiredVersion, versions),
			data.expected,
			fmt.Sprintf("failed for test data %+v", data),
		)
	}
}

// ---

var istioVersionDataProvider = []struct {
	requiredVersion string
	clientVersion   string
	expected        bool
}{
	{"0.2.4", "0.2.1", false},
	{"0.2.4", "0.2.4", true},
	{"0.3.0", "0.2.4", false},
	{"1.0.0", "0.2.4", false},
}

func (suite *BinctlTestSuite) TestCheckIstioctlVersion() {
	for _, data := range istioVersionDataProvider {

		versions := struct {
			Client string
		}{data.clientVersion}

		assert.Equal(suite.T(),
			CheckIstioctlVersion(data.requiredVersion, versions),
			data.expected,
			fmt.Sprintf("failed for test data %+v", data),
		)
	}
}
