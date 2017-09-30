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

type YamlParseTestSuite struct {
	suite.Suite
	KubectlPath string
}

func (suite *YamlParseTestSuite) SetupTest() {
	suite.KubectlPath = kubectlPath
}

func TestParseRouteRule(t *testing.T) {

	routeruleYaml := `apiVersion: config.istio.io/v1alpha2
kind: RouteRule
metadata:
  creationTimestamp: null
  name: details-default
  namespace: default
  resourceVersion: "11464"
spec:
  destination:
    name: details
  precedence: 1
  route:
  - labels:
      version: v1
`

	routerule := getRouteRule(routeruleYaml)

	assert.IsType(t, RouteRule{}, routerule)
	assert.Equal(t, routerule.Spec.Destination.Name, "details")
}

func TestGetHighestPrecedence(t *testing.T) {
	highestPrecedence := getHighestPrecedence()
	assert.Equal(t, 100, highestPrecedence)
}
