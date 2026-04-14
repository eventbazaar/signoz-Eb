package googlechat

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	test "github.com/SigNoz/signoz/pkg/alertmanager/alertmanagernotify/alertmanagernotifytest"
	"github.com/prometheus/alertmanager/config"
	"github.com/prometheus/alertmanager/notify"
	"github.com/prometheus/alertmanager/types"
	commoncfg "github.com/prometheus/common/config"
	"github.com/prometheus/common/model"
	"github.com/prometheus/common/promslog"
	"github.com/stretchr/testify/require"
)

func TestGoogleChatRetry(t *testing.T) {
	notifier, err := New(
		&config.WebhookConfig{
			URL:        config.SecretTemplateURL("https://chat.googleapis.com/v1/spaces/xxx/messages?key=xxx&token=xxx"),
			HTTPConfig: &commoncfg.HTTPClientConfig{},
		},
		test.CreateTmpl(t),
		promslog.NewNopLogger(),
	)
	require.NoError(t, err)

	for statusCode, expected := range test.RetryTests(test.DefaultRetryCodes()) {
		actual, _ := notifier.retrier.Check(statusCode, nil)
		require.Equal(t, expected, actual, "retry - error on status %d", statusCode)
	}
}

func TestGoogleChatNotify(t *testing.T) {
	var receivedBody map[string]any

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		dec := json.NewDecoder(r.Body)
		err := dec.Decode(&receivedBody)
		if err != nil {
			t.Fatalf("failed to decode request body: %v", err)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	notifier, err := New(
		&config.WebhookConfig{
			URL:        config.SecretTemplateURL(srv.URL),
			HTTPConfig: &commoncfg.HTTPClientConfig{},
		},
		test.CreateTmpl(t),
		promslog.NewNopLogger(),
	)
	require.NoError(t, err)

	ctx := context.Background()
	ctx = notify.WithGroupKey(ctx, "1")

	alert1 := &types.Alert{
		Alert: model.Alert{
			Labels: model.LabelSet{
				"alertname": "TestAlert",
				"severity":  "critical",
			},
			Annotations: model.LabelSet{
				"description": "This is a test alert",
			},
			StartsAt: time.Now(),
			EndsAt:   time.Now().Add(time.Hour),
		},
	}

	retry, err := notifier.Notify(ctx, alert1)
	require.NoError(t, err)
	require.False(t, retry)

	require.Contains(t, receivedBody, "text")
	text, ok := receivedBody["text"].(string)
	require.True(t, ok)
	require.Contains(t, text, "FIRING")
	require.Contains(t, text, "TestAlert")
	require.Contains(t, text, "severity")
	require.Contains(t, text, "critical")
	require.Contains(t, text, "description")
	require.Contains(t, text, "This is a test alert")

	require.NotContains(t, receivedBody, "receiver")
	require.NotContains(t, receivedBody, "alerts")
	require.NotContains(t, receivedBody, "groupLabels")
}

func TestGoogleChatNotifyWithReason(t *testing.T) {
	tests := []struct {
		name            string
		statusCode      int
		responseContent string
		expectedReason  notify.Reason
		noError         bool
	}{
		{
			name:            "with a 2xx status code",
			statusCode:      http.StatusOK,
			responseContent: "{}",
			noError:         true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			notifier, err := New(
				&config.WebhookConfig{
					URL:        config.SecretTemplateURL("https://chat.googleapis.com/v1/spaces/xxx/messages?key=xxx&token=xxx"),
					HTTPConfig: &commoncfg.HTTPClientConfig{},
				},
				test.CreateTmpl(t),
				promslog.NewNopLogger(),
			)
			require.NoError(t, err)

			notifier.postJSONFunc = func(ctx context.Context, client *http.Client, url string, body io.Reader) (*http.Response, error) {
				resp := httptest.NewRecorder()
				_, err := resp.WriteString(tt.responseContent)
				require.NoError(t, err)
				resp.WriteHeader(tt.statusCode)
				return resp.Result(), nil
			}

			ctx := context.Background()
			ctx = notify.WithGroupKey(ctx, "1")

			alert1 := &types.Alert{
				Alert: model.Alert{
					Labels: model.LabelSet{
						"alertname": "TestAlert",
					},
					StartsAt: time.Now(),
					EndsAt:   time.Now().Add(time.Hour),
				},
			}
			_, err = notifier.Notify(ctx, alert1)
			if tt.noError {
				require.NoError(t, err)
			} else {
				var reasonError *notify.ErrorWithReason
				require.ErrorAs(t, err, &reasonError)
				require.Equal(t, tt.expectedReason, reasonError.Reason)
			}
		})
	}
}

func TestGoogleChatRedactedURL(t *testing.T) {
	ctx, u, fn := test.GetContextWithCancelingURL()
	defer fn()

	secret := "secret"
	notifier, err := New(
		&config.WebhookConfig{
			URL:        config.SecretTemplateURL(u.String()),
			HTTPConfig: &commoncfg.HTTPClientConfig{},
		},
		test.CreateTmpl(t),
		promslog.NewNopLogger(),
	)
	require.NoError(t, err)

	test.AssertNotifyLeaksNoSecret(ctx, t, notifier, secret)
}

func TestIsGoogleChatURL(t *testing.T) {
	tests := []struct {
		url      string
		expected bool
	}{
		{
			url:      "https://chat.googleapis.com/v1/spaces/XXXXX/messages?key=test-key&token=test-token",
			expected: true,
		},
		{
			url:      "https://hooks.example.com/services/T00000000/B00000000/XXXXXXXX",
			expected: false,
		},
		{
			url:      "https://example.com/webhook",
			expected: false,
		},
		{
			url:      "",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.url, func(t *testing.T) {
			require.Equal(t, tt.expected, IsGoogleChatURL(tt.url))
		})
	}
}

func TestGoogleChatPayloadFormat(t *testing.T) {
	var receivedKeys []string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		dec := json.NewDecoder(r.Body)
		err := dec.Decode(&body)
		if err != nil {
			t.Fatalf("failed to decode request body: %v", err)
		}
		for k := range body {
			receivedKeys = append(receivedKeys, k)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	notifier, err := New(
		&config.WebhookConfig{
			URL:        config.SecretTemplateURL(srv.URL),
			HTTPConfig: &commoncfg.HTTPClientConfig{},
		},
		test.CreateTmpl(t),
		promslog.NewNopLogger(),
	)
	require.NoError(t, err)

	ctx := context.Background()
	ctx = notify.WithGroupKey(ctx, "1")

	_, err = notifier.Notify(ctx, &types.Alert{
		Alert: model.Alert{
			Labels:   model.LabelSet{"alertname": "Test"},
			StartsAt: time.Now(),
			EndsAt:   time.Now().Add(time.Hour),
		},
	})
	require.NoError(t, err)

	require.Equal(t, []string{"text"}, receivedKeys, "Google Chat payload should only contain 'text' field")
}
