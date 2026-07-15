package protocol

import (
	"context"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"

	"github.com/yangy003/ap-ios-debug-system/internal/contract"
)

const maxScreenshotBytes int64 = 25 << 20

type ScreenshotMeta struct {
	CaptureMethod string  `json:"capture_method"`
	PixelWidth    int     `json:"pixel_width"`
	PixelHeight   int     `json:"pixel_height"`
	Scale         float64 `json:"scale"`
}

type Screenshot struct {
	client *Client
}

func NewScreenshot(client *Client) Screenshot {
	return Screenshot{client: client}
}

func (s Screenshot) Capture(ctx context.Context) (*BinaryResponse, ScreenshotMeta, error) {
	response, err := s.client.OpenBinary(ctx, "/v1/screenshot", "image/png", maxScreenshotBytes)
	if err != nil {
		return nil, ScreenshotMeta{}, err
	}
	meta, err := parseScreenshotMeta(response.Header)
	if err != nil {
		_ = response.Body.Close()
		return nil, ScreenshotMeta{}, contract.New(contract.ProtocolMismatch, err)
	}
	return response, meta, nil
}

func parseScreenshotMeta(header http.Header) (ScreenshotMeta, error) {
	method, ok := singleHeader(header, "X-IOS-Debug-Capture-Method")
	if !ok || strings.TrimSpace(method) == "" {
		return ScreenshotMeta{}, fmt.Errorf("invalid capture method")
	}
	width, err := positiveIntHeader(header, "X-IOS-Debug-Pixel-Width")
	if err != nil {
		return ScreenshotMeta{}, err
	}
	height, err := positiveIntHeader(header, "X-IOS-Debug-Pixel-Height")
	if err != nil {
		return ScreenshotMeta{}, err
	}
	scaleRaw, ok := singleHeader(header, "X-IOS-Debug-Scale")
	if !ok {
		return ScreenshotMeta{}, fmt.Errorf("missing scale")
	}
	scale, err := strconv.ParseFloat(scaleRaw, 64)
	if err != nil || scale <= 0 || math.IsInf(scale, 0) || math.IsNaN(scale) {
		return ScreenshotMeta{}, fmt.Errorf("invalid scale")
	}
	return ScreenshotMeta{CaptureMethod: method, PixelWidth: width, PixelHeight: height, Scale: scale}, nil
}

func positiveIntHeader(header http.Header, name string) (int, error) {
	raw, ok := singleHeader(header, name)
	if !ok {
		return 0, fmt.Errorf("missing %s", name)
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return 0, fmt.Errorf("invalid %s", name)
	}
	return value, nil
}
