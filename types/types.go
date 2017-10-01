package types

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
