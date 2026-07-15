package config

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"

	"github.com/pelletier/go-toml/v2"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/contract"
)

const (
	defaultPort      = uint16(9876)
	defaultTransport = "usb"
	defaultTCPHost   = "127.0.0.1"
)

func Load(ctx context.Context, options LoadOptions) (Config, error) {
	workingDir, err := absoluteDirectory(options.WorkingDir, os.Getwd)
	if err != nil {
		return Config{}, invalid(errors.New("working directory is unavailable"))
	}
	userHome, err := absoluteDirectory(options.UserHome, os.UserHomeDir)
	if err != nil {
		return Config{}, invalid(errors.New("user home is unavailable"))
	}

	result := Config{
		Port:       defaultPort,
		OutputDir:  filepath.Join(workingDir, ".ap-ios-debug", "artifacts"),
		Transport:  defaultTransport,
		TCPHost:    defaultTCPHost,
		WorkingDir: workingDir,
	}
	tcpHostSet := false

	userPath := filepath.Join(userHome, ".ap-ios-debug", "config.toml")
	user, exists, err := loadFile(userPath)
	if err != nil {
		return Config{}, err
	}
	if exists {
		if err := applyFile(&result, user, filepath.Dir(userPath), &tcpHostSet); err != nil {
			return Config{}, err
		}
	}

	projectPath := filepath.Join(workingDir, ".ap-ios-debug.toml")
	project, exists, err := loadFile(projectPath)
	if err != nil {
		return Config{}, err
	}
	if exists {
		if err := applyFile(&result, project, workingDir, &tcpHostSet); err != nil {
			return Config{}, err
		}
	}

	lookupEnv := options.LookupEnv
	if lookupEnv == nil {
		lookupEnv = os.LookupEnv
	}
	if value, ok := lookupEnv("AP_IOS_DEBUG_DEVICE"); ok {
		if value == "" {
			return Config{}, invalid(errors.New("device identifier cannot be empty"))
		}
		result.DeviceID = value
	}
	if value, ok := lookupEnv("AP_IOS_DEBUG_PORT"); ok {
		port, parseErr := strconv.ParseUint(value, 10, 16)
		if parseErr != nil || port == 0 {
			return Config{}, invalid(errors.New("AP_IOS_DEBUG_PORT must be between 1 and 65535"))
		}
		result.Port = uint16(port)
	}
	if value, ok := lookupEnv("AP_IOS_DEBUG_OUTPUT_DIR"); ok {
		if value == "" {
			return Config{}, invalid(errors.New("output directory cannot be empty"))
		}
		result.OutputDir = resolvePath(workingDir, value)
	}
	if value, ok := lookupEnv("AP_IOS_DEBUG_TOKEN"); ok {
		result.Token = value
	}

	if options.CLI.DeviceID != nil {
		if *options.CLI.DeviceID == "" {
			return Config{}, invalid(errors.New("device identifier cannot be empty"))
		}
		result.DeviceID = *options.CLI.DeviceID
	}
	if options.CLI.Port != nil {
		result.Port = *options.CLI.Port
	}
	if options.CLI.OutputDir != nil {
		if *options.CLI.OutputDir == "" {
			return Config{}, invalid(errors.New("output directory cannot be empty"))
		}
		result.OutputDir = resolvePath(workingDir, *options.CLI.OutputDir)
	}
	if options.CLI.Transport != nil {
		if *options.CLI.Transport == "" {
			return Config{}, invalid(errors.New("transport cannot be empty"))
		}
		result.Transport = *options.CLI.Transport
	}
	if options.CLI.TCPHost != nil {
		if *options.CLI.TCPHost == "" {
			return Config{}, invalid(errors.New("TCP host cannot be empty"))
		}
		result.TCPHost = *options.CLI.TCPHost
		tcpHostSet = true
	}

	if err := validate(ctx, result, tcpHostSet); err != nil {
		return Config{}, err
	}
	result.OutputDir = filepath.Clean(result.OutputDir)
	return result, nil
}

func absoluteDirectory(value string, fallback func() (string, error)) (string, error) {
	if value == "" {
		var err error
		value, err = fallback()
		if err != nil {
			return "", err
		}
	}
	return filepath.Abs(value)
}

func loadFile(path string) (fileConfig, bool, error) {
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return fileConfig{}, false, nil
	}
	if err != nil {
		return fileConfig{}, false, invalid(fmt.Errorf("open configuration: %w", err))
	}
	defer file.Close()

	var value fileConfig
	decoder := toml.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return fileConfig{}, false, invalid(fmt.Errorf("decode configuration: %w", err))
	}
	if value.Token != nil {
		return fileConfig{}, false, invalid(errors.New("token is not permitted in TOML configuration"))
	}
	return value, true, nil
}

func applyFile(result *Config, source fileConfig, outputBase string, tcpHostSet *bool) error {
	if source.Device != nil {
		if *source.Device == "" {
			return invalid(errors.New("device identifier cannot be empty"))
		}
		result.DeviceID = *source.Device
	}
	if source.Port != nil {
		result.Port = *source.Port
	}
	if source.OutputDir != nil {
		if *source.OutputDir == "" {
			return invalid(errors.New("output directory cannot be empty"))
		}
		result.OutputDir = resolvePath(outputBase, *source.OutputDir)
	}
	if source.Transport != nil {
		if *source.Transport == "" {
			return invalid(errors.New("transport cannot be empty"))
		}
		result.Transport = *source.Transport
	}
	if source.TCPHost != nil {
		if *source.TCPHost == "" {
			return invalid(errors.New("TCP host cannot be empty"))
		}
		result.TCPHost = *source.TCPHost
		*tcpHostSet = true
	}
	return nil
}

func resolvePath(base, value string) string {
	if filepath.IsAbs(value) {
		return filepath.Clean(value)
	}
	return filepath.Join(base, value)
}

func validate(ctx context.Context, result Config, tcpHostSet bool) error {
	if result.Port == 0 {
		return invalid(errors.New("port must be between 1 and 65535"))
	}
	if result.OutputDir == "" {
		return invalid(errors.New("output directory cannot be empty"))
	}
	if result.Transport != "usb" && result.Transport != "tcp" {
		return invalid(errors.New("transport must be usb or tcp"))
	}
	if result.TCPHost == "" {
		return invalid(errors.New("TCP host cannot be empty"))
	}
	if result.Transport == "usb" {
		if tcpHostSet {
			return invalid(errors.New("TCP host is valid only with TCP transport"))
		}
		return nil
	}

	addresses, err := net.DefaultResolver.LookupIPAddr(ctx, result.TCPHost)
	if err != nil || len(addresses) == 0 {
		return invalid(errors.New("TCP host must resolve to a loopback address"))
	}
	for _, address := range addresses {
		if !address.IP.IsLoopback() {
			return invalid(errors.New("TCP host must resolve only to loopback addresses"))
		}
	}
	return nil
}

func invalid(cause error) error {
	return contract.New(contract.ConfigInvalid, cause)
}
