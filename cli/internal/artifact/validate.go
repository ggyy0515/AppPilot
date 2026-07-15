package artifact

import (
	"image/png"
	"os"

	"github.com/yangy003/ap-ios-debug-system/internal/contract"
)

func ValidatePNG(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return contract.New(contract.IOFailure, err)
	}
	defer file.Close()
	if _, err := png.DecodeConfig(file); err != nil {
		return contract.New(contract.ScreenshotFailed, err)
	}
	return nil
}
