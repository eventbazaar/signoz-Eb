package googlechat

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"

	"github.com/prometheus/alertmanager/config"
	"github.com/prometheus/alertmanager/notify"
	"github.com/prometheus/alertmanager/template"
	"github.com/prometheus/alertmanager/types"
	commoncfg "github.com/prometheus/common/config"
	"github.com/prometheus/common/model"
)

type Notifier struct {
	conf         *config.WebhookConfig
	tmpl         *template.Template
	logger       *slog.Logger
	client       *http.Client
	retrier      *notify.Retrier
	postJSONFunc func(ctx context.Context, client *http.Client, url string, body io.Reader) (*http.Response, error)
}

type googleChatMessage struct {
	Text string `json:"text"`
}

func New(c *config.WebhookConfig, t *template.Template, l *slog.Logger, httpOpts ...commoncfg.HTTPClientOption) (*Notifier, error) {
	client, err := commoncfg.NewClientFromConfig(*c.HTTPConfig, "googlechat", httpOpts...)
	if err != nil {
		return nil, err
	}

	return &Notifier{
		conf:         c,
		tmpl:         t,
		logger:       l,
		client:       client,
		retrier:      &notify.Retrier{},
		postJSONFunc: notify.PostJSON,
	}, nil
}

func (n *Notifier) Notify(ctx context.Context, as ...*types.Alert) (bool, error) {
	key, err := notify.ExtractGroupKey(ctx)
	if err != nil {
		return false, err
	}
	n.logger.DebugContext(ctx, "extracted group key", slog.String("key", string(key)))

	data := notify.GetTemplateData(ctx, n.tmpl, as, n.logger)

	alerts := types.Alerts(as...)
	var statusIcon string
	switch alerts.Status() {
	case model.AlertFiring:
		statusIcon = "🔴"
	case model.AlertResolved:
		statusIcon = "✅"
	default:
		statusIcon = "⚠️"
	}

	var text strings.Builder
	fmt.Fprintf(&text, "%s *[%s:%d] %s*\n",
		statusIcon,
		strings.ToUpper(string(data.Status)),
		len(data.Alerts),
		data.CommonLabels["alertname"],
	)

	for i, alert := range data.Alerts {
		if i > 0 {
			text.WriteString("\n---\n")
		}
		text.WriteString("\n")

		alertStatus := "firing"
		if alert.Status == string(model.AlertResolved) {
			alertStatus = "resolved"
		}
		fmt.Fprintf(&text, "*Alert %d — %s*\n", i+1, alertStatus)

		if len(alert.Labels) > 0 {
			text.WriteString("*Labels:*\n")
			for _, pair := range alert.Labels.SortedPairs() {
				fmt.Fprintf(&text, "  • %s = `%s`\n", pair.Name, pair.Value)
			}
		}

		if len(alert.Annotations) > 0 {
			text.WriteString("*Annotations:*\n")
			for _, pair := range alert.Annotations.SortedPairs() {
				fmt.Fprintf(&text, "  • %s = %s\n", pair.Name, pair.Value)
			}
		}
	}

	if data.ExternalURL != "" {
		fmt.Fprintf(&text, "\n%s", data.ExternalURL)
	}

	msg := googleChatMessage{
		Text: text.String(),
	}

	var url string
	if n.conf.URL != "" {
		url = string(n.conf.URL)
	} else if n.conf.URLFile != "" {
		content, err := os.ReadFile(n.conf.URLFile)
		if err != nil {
			return false, fmt.Errorf("read url_file: %w", err)
		}
		url = strings.TrimSpace(string(content))
	}

	if url == "" {
		return false, fmt.Errorf("google chat webhook URL is empty")
	}

	var payload bytes.Buffer
	if err = json.NewEncoder(&payload).Encode(msg); err != nil {
		return false, err
	}

	if n.conf.Timeout > 0 {
		postCtx, cancel := context.WithTimeoutCause(ctx, n.conf.Timeout, fmt.Errorf("configured webhook timeout reached (%s)", n.conf.Timeout))
		defer cancel()
		ctx = postCtx
	}

	resp, err := n.postJSONFunc(ctx, n.client, url, &payload)
	if err != nil {
		return true, notify.RedactURL(err)
	}
	defer notify.Drain(resp)

	shouldRetry, err := n.retrier.Check(resp.StatusCode, resp.Body)
	if err != nil {
		return shouldRetry, notify.NewErrorWithReason(notify.GetFailureReasonFromStatusCode(resp.StatusCode), err)
	}
	return shouldRetry, err
}

// IsGoogleChatURL returns true if the given URL string points to a Google Chat webhook endpoint.
func IsGoogleChatURL(rawURL string) bool {
	return strings.Contains(rawURL, "chat.googleapis.com/")
}
