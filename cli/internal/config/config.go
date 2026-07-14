package config

type Config struct {
	DeviceID   string
	Port       uint16
	OutputDir  string
	Token      string
	Transport  string
	TCPHost    string
	WorkingDir string
}

type CLIValues struct {
	DeviceID  *string
	Port      *uint16
	OutputDir *string
	Transport *string
	TCPHost   *string
}

type LoadOptions struct {
	CLI        CLIValues
	LookupEnv  func(string) (string, bool)
	WorkingDir string
	UserHome   string
}

type fileConfig struct {
	Device    *string `toml:"device"`
	Port      *uint16 `toml:"port"`
	OutputDir *string `toml:"output_dir"`
	Transport *string `toml:"transport"`
	TCPHost   *string `toml:"tcp_host"`
	Token     *string `toml:"token"`
}
