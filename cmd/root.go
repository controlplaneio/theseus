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

  homedir "github.com/mitchellh/go-homedir"
  "github.com/spf13/cobra"
  "github.com/spf13/viper"
)

var cfgFile string

var buildStamp = "unknown"
var gitHash = "unknown"
var buildVersion = "unknown"

var (
  isVersionFlag  bool = false
  timeoutSeconds int
  tag            string
  tagName        string
  weight         string
  precedence     string
  name           string
  header         string
  regex          string
  cookie         string
  userAgent      string
  testUrl        string
  test           string
  backup         bool
  undeploy       string
  delete         bool
  debug          bool
  dryRun         bool

  RootCmd = &cobra.Command{
    Use:   "theseus",
    Short: "Continuous Zero-Downtime Deployments for Kubernetes & Istio",
    Long: `Perform continually-tested and monitored roll-outs to a Kubernetes microservice application.

This project is currently in alpha, feedback and PRs welcome.`,
    Run: func(cmd *cobra.Command, args []string) {
      theseus(cmd, args)
    },
  }
)

func theseus(cmd *cobra.Command, args []string) {

  if isVersionFlag {
    fmt.Fprintf(os.Stderr, "%s %s (build %s %s)\n", os.Args[0], buildVersion, gitHash, buildStamp)
    os.Exit(0)
  }

}

// Execute adds all child commands to the root command and sets flags appropriately.
// This is called by main.main(). It only needs to happen once to the rootCmd.
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
    &delete,
    "delete",
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



  //RootCmd.PersistentFlags().BoolVarP(
  //  &isStdLib,
  //  "stdlib",
  //  "s",
  //  false,
  //  "Use the Go standard rexexp library",
  //)
  RootCmd.PersistentFlags().IntVarP(
    &timeoutSeconds,
    "timeout",
    "",
    0,
    "Total execution timeout",
  )

  RootCmd.PersistentFlags().StringVar(&cfgFile, "config", "", "config file (default is $HOME/.theseus.yaml)")

  // Cobra also supports local flags, which will only run
  // when this action is called directly.
  //RootCmd.Flags().BoolP("toggle", "t", false, "Help message for toggle")
}

// initConfig reads in config file and ENV variables if set.
func initConfig() {
  if cfgFile != "" {
    // Use config file from the flag.
    viper.SetConfigFile(cfgFile)
  } else {
    // Find home directory.
    home, err := homedir.Dir()
    if err != nil {
      fmt.Println(err)
      os.Exit(1)
    }

    // Search config in home directory with name ".theseus" (without extension).
    viper.AddConfigPath(home)
    viper.SetConfigName(".theseus")
  }

  viper.AutomaticEnv() // read in environment variables that match

  // If a config file is found, read it in.
  if err := viper.ReadInConfig(); err == nil {
    fmt.Println("Using config file:", viper.ConfigFileUsed())
  }
}
