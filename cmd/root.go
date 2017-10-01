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
	"fmt"
	"os"
	"sort"

	"github.com/mitchellh/go-homedir"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
	"gopkg.in/yaml.v2"

	"github.com/controlplaneio/theseus/binctl"
	logging "github.com/op/go-logging"
)

var cfgFile string

var buildStamp = "unknown"
var gitHash = "unknown"
var buildVersion = "unknown"

var (
	minIstioctlVersion = "0.2.4"
	minKubectlVersion  = "1.7.0"

	isVersionFlag    bool = false
	timeoutSeconds   int
	tag              string
	tagName          string
	weight           string
	precedence       string
	name             string
	header           string
	regex            string
	cookie           string
	userAgent        string
	testUrl          string
	test             string
	backup           bool
	undeploy         string
	deleteDeployment bool
	debug            bool
	dryRun           bool

	RootCmd = &cobra.Command{
		Use:   "theseus",
		Short: "Continuous Zero-Downtime Deployments for Kubernetes & Istio",
		Long: `Perform continually-tested and monitored roll-outs to a Kubernetes microservice application.

This project is currently in alpha, feedback and PRs welcome.`,
		Run: func(cmd *cobra.Command, args []string) {
			theseus(cmd, args)
		},
	}

	log = logging.MustGetLogger("example")
)

type RouteRule struct {
	APIVersion string `yaml:"apiVersion"`
	Kind       string `yaml:"kind"`
	Metadata   struct {
		Name string `yaml:"name"`
	} `yaml:"metadata"`
	Spec struct {
		Destination struct {
			Name string `yaml:"name"`
		} `yaml:"destination"`
		Match struct {
			Request struct {
				Headers struct {
					Cookie struct {
						Regex string `yaml:"regex"`
					} `yaml:"cookie"`
				} `yaml:"headers"`
			} `yaml:"request"`
		} `yaml:"match"`
		Precedence int `yaml:"precedence"`
		Route      []struct {
			Labels struct {
				Version string `yaml:"version"`
			} `yaml:"labels"`
		} `yaml:"route"`
	} `yaml:"spec"`
}

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

func theseus(cmd *cobra.Command, args []string) {

	setupLogging()

	if isVersionFlag {
		fmt.Fprintf(os.Stderr, "%s %s (build %s %s)\n", os.Args[0], buildVersion, gitHash, buildStamp)
		os.Exit(0)
	}

	log.Info("check_kubernetes_version")
	if !binctl.CheckKubectlVersion(minKubectlVersion) {
		log.Error("kubectl version %s or greater required", minKubectlVersion)
		os.Exit(1)
	}

	log.Info("check_istio_version")
	if !binctl.CheckIstioctlVersion(minIstioctlVersion) {
		log.Error("istioctl version %s or greater required", minIstioctlVersion)
		os.Exit(1)
	}

	log.Info("check_for_autoscaler")
	log.Info("if IS_DELETE - delete_route_and_deployment")
	log.Info("get highest precedence")

	log.Info("generate_route")
	log.Info("trap 'rollback' EXIT")
	log.Info("deploy_resource ${FILENAME}")

	log.Info("if ! wait_for_deployment Deployment failed, rolling back")
	log.Info("deploy_rule_safe")

	log.Info("if ! test_resource; then Deployment failed, rolling back")
	log.Info("deploy_rule_full_rollout")

	log.Info("if ! test_resource; then Deployment failed during full rollout, rolling back")

	log.Info("undeploy_previous_deployment")
	log.Info("trap - EXIT")
	log.Info("undeploy_deployment")

	log.Info("Deployment of ${FILENAME} succeeded in ${SECONDS}")

	os.Exit(1)
}

func getRouteRule(routeruleYaml string) RouteRule {
	routerule := RouteRule{}
	err := yaml.Unmarshal([]byte(routeruleYaml), &routerule)
	if err != nil {
		panic(err)
	}
	//log.Info("--- t:\n%+v\n\n", routerule)
	return routerule
}

func getHighestPrecedence(rules []RouteRule) int {
	sortRouteRules(rules)
	return rules[0].Spec.Precedence
}

// simplified from https://github.com/istio/pilot/blob/master/model/config.go#L378-L389
// TODO(ajm): sort by high precedence first, key string second (keys are unique)
// TODO(ajm): protect against incompatible types
func sortRouteRules(rules []RouteRule) {
	log.Info("sorting route")
	sort.Slice(rules, func(i, j int) bool {
		irule := rules[i].Spec
		jrule := rules[j].Spec
		if irule.Destination != jrule.Destination {
			panic("Routerule destinations do not match")
		}
		return irule.Precedence > jrule.Precedence
	})
}

// ---

func Execute() {
	if err := RootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

func init() {
	cobra.OnInitialize(initConfig)

	RootCmd.PersistentFlags().StringVarP(
		&tag,
		"tag",
		"",
		"",
		"Value to pod to route to (.metadata.labels, required)",
	)
	RootCmd.PersistentFlags().StringVarP(
		&tagName,
		"tagName",
		"",
		"",
		"New tag of service to deploy (from .metadata.labels, default: version)",
	)
	RootCmd.PersistentFlags().StringVarP(
		&weight,
		"weight",
		"",
		"",
		"Percentage of traffic to redirect to tag",
	)
	RootCmd.PersistentFlags().StringVarP(
		&precedence,
		"precedence",
		"",
		"",
		"Precedence (default: 10)",
	)
	RootCmd.PersistentFlags().StringVarP(
		&name,
		"name",
		"",
		"",
		"Rule name (default: `destination`-test-`tag`)",
	)
	RootCmd.PersistentFlags().StringVarP(
		&header,
		"header",
		"",
		"",
		"HTTP header to route on",
	)
	RootCmd.PersistentFlags().StringVarP(
		&regex,
		"regex",
		"",
		"",
		"An inclusion regex to apply to the HTTP header",
	)
	RootCmd.PersistentFlags().StringVarP(
		&cookie,
		"cookie",
		"",
		"",
		"Implies `--header cookie --regex [regex]`",
	)
	RootCmd.PersistentFlags().StringVarP(
		&userAgent,
		"userAgent",
		"",
		"",
		"Implies `--header user-agent --regex [regex]`",
	)
	RootCmd.PersistentFlags().StringVarP(
		&testUrl,
		"testUrl",
		"",
		"",
		"URL to test deployment by `curl`-ing for status 200",
	)
	RootCmd.PersistentFlags().StringVarP(
		&test,
		"test",
		"",
		"",
		`Script or command to eval to test deployment
														The environment variable GATEWAY_URL is available
														e.g. --test "curl --fail \${GATEWAY_URL}`,
	)
	RootCmd.PersistentFlags().BoolVarP(
		&backup,
		"backup",
		"",
		false,
		"Backup existing deployment",
	)
	RootCmd.PersistentFlags().StringVarP(
		&undeploy,
		"undeploy",
		"",
		"",
		"undeploy - TODO",
	)
	RootCmd.PersistentFlags().BoolVarP(
		&deleteDeployment,
		"deleteDeployment",
		"",
		false,
		"Remove existing deployment and route",
	)
	RootCmd.PersistentFlags().BoolVarP(
		&debug,
		"debug",
		"",
		false,
		"More debug",
	)
	RootCmd.PersistentFlags().BoolVarP(
		&dryRun,
		"dryRun",
		"",
		false,
		"Dry-run; only show what would be done",
	)

	// ---

	RootCmd.PersistentFlags().BoolVarP(
		&isVersionFlag,
		"version",
		"v",
		false,
		"Version",
	)

	RootCmd.PersistentFlags().IntVarP(
		&timeoutSeconds,
		"timeout",
		"",
		0,
		"Total execution timeout",
	)

	RootCmd.PersistentFlags().StringVar(
		&cfgFile,
		"config",
		"",
		"config file (default is $HOME/.theseus.yaml)",
	)
}

func initConfig() {
	if cfgFile != "" {
		viper.SetConfigFile(cfgFile)
	} else {
		home, err := homedir.Dir()
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}

		viper.AddConfigPath(home)
		viper.SetConfigName(".theseus")
	}

	viper.AutomaticEnv()

	if err := viper.ReadInConfig(); err == nil {
		fmt.Println("Using config file:", viper.ConfigFileUsed())
	}
}
