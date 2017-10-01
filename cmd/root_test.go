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

	"github.com/controlplaneio/theseus/types"
)

type RootTestSuite struct {
	suite.Suite
	RouteruleYaml                 string
	RouteruleHigherPrecedenceYaml string
	RouteruleOtherDestination     string
}

// run suite tests
func TestYamlParseTestSuite(t *testing.T) {
	suite.Run(t, new(RootTestSuite))
}

func (suite *RootTestSuite) SetupTest() {
	suite.RouteruleYaml = `apiVersion: config.istio.io/v1alpha2
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

	suite.RouteruleHigherPrecedenceYaml = `apiVersion: config.istio.io/v1alpha2
kind: RouteRule
metadata:
  name: details-default-2
spec:
  destination:
    name: details
  precedence: 2123
  route:
  - labels:
      version: v1
`
	suite.RouteruleOtherDestination = `apiVersion: config.istio.io/v1alpha2
kind: RouteRule
metadata:
  name: other-name
spec:
  destination:
    name: other-name
  precedence: 9999
`
}

func (suite *RootTestSuite) TestParseRouteRule() {
	routerule := getRouteRule(suite.RouteruleYaml)

	assert.IsType(suite.T(), types.RouteRule{}, routerule)
	assert.Equal(suite.T(), routerule.Spec.Destination.Name, "details")
}

func (suite *RootTestSuite) TestGetHighestPrecedenceRouteRule() {
	highestPrecedenceRouteRule := getRouteRule(suite.RouteruleHigherPrecedenceYaml)
	SortedRules := []types.RouteRule{
		getRouteRule(suite.RouteruleYaml),
		highestPrecedenceRouteRule,
	}

	sortRouteRules(SortedRules)

	assert.Equal(suite.T(),
		SortedRules[0].Spec.Precedence,
		highestPrecedenceRouteRule.Spec.Precedence,
	)
}

func (suite *RootTestSuite) TestGetHighestPrecedence() {
	SortedRules := []types.RouteRule{
		getRouteRule(suite.RouteruleYaml),
		getRouteRule(suite.RouteruleHigherPrecedenceYaml),
	}

	highestPrecedence := getHighestPrecedence(SortedRules)

	assert.Equal(suite.T(), highestPrecedence, 2123)
}

func (suite *RootTestSuite) TestGetHighestPrecedencePanicsWithDifferentTypes() {
	SortedRules := []types.RouteRule{
		getRouteRule(suite.RouteruleYaml),
		getRouteRule(suite.RouteruleHigherPrecedenceYaml),
		getRouteRule(suite.RouteruleOtherDestination),
	}

	assert.Panics(suite.T(), func() { getHighestPrecedence(SortedRules) })
}
