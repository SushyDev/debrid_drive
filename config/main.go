package config

import (
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Port            int    `yaml:"port"`
	ContentType     string `yaml:"content_type"`
	RealDebridToken string `yaml:"real_debrid_token"`
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

func GetPort() int {
	cfg := get()

	return cfg.Port
}

func GetContentType() string {
	cfg := get()

	return cfg.ContentType
}

func GetRealDebridToken() string {
	cfg := get()

	return cfg.RealDebridToken
}
