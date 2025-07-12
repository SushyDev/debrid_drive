package config

import (
	"os"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	ContentType           string `yaml:"content_type"`
	PollUrl               string `yaml:"poll_url"`
	PollIntervalSeconds   int    `yaml:"poll_interval_seconds"`
	Port                  int    `yaml:"port"`
	RealDebridToken       string `yaml:"real_debrid_token"`
	UseFilenameInLister   bool   `yaml:"use_filename_in_lister"`
	UseIdInFilenameLister bool   `yaml:"use_id_in_filename_lister"`
}

func get() Config {
	file, err := os.Open("config.yml")
	if err != nil {
		panic(err)
	}
	defer file.Close()

	decoder := yaml.NewDecoder(file)
	var cfg Config
	if err := decoder.Decode(&cfg); err != nil {
		panic(err)
	}

	return cfg
}

func Validate() {
	cfg := get()

	if cfg.Port == 0 {
		panic("Port is not set")
	}

	if cfg.ContentType == "" {
		panic("Content type is not set")
	}

	if cfg.RealDebridToken == "" {
		panic("Real Debrid token is not set")
	}
}

func GetContentType() string {
	cfg := get()

	return cfg.ContentType
}

func GetPollUrl() string {
	cfg := get()

	return cfg.PollUrl
}

func GetPollIntervalSeconds() time.Duration {
	cfg := get()

	if cfg.PollIntervalSeconds == 0 {
		return 60 * time.Second
	}

	return time.Duration(cfg.PollIntervalSeconds) * time.Second
}

func GetPort() int {
	cfg := get()

	return cfg.Port
}

func GetRealDebridToken() string {
	cfg := get()

	return cfg.RealDebridToken
}

func GetUseFilenameInLister() bool {
	cfg := get()

	return cfg.UseFilenameInLister
}

func GetUseIdInFilenameLister() bool {
	cfg := get()

	return cfg.UseIdInFilenameLister
}
