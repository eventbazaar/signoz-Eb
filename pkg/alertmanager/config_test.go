package alertmanager

import (
	"context"
	"net/url"
	"testing"
	"time"

	"github.com/knadh/koanf/providers/confmap"
	"github.com/prometheus/common/model"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	yamlv2 "gopkg.in/yaml.v2"

	"github.com/SigNoz/signoz/pkg/config"
	"github.com/SigNoz/signoz/pkg/config/envprovider"
	"github.com/SigNoz/signoz/pkg/factory"
)

func TestNewWithEnvProvider(t *testing.T) {
	t.Setenv("SIGNOZ_ALERTMANAGER_PROVIDER", "signoz")
	t.Setenv("SIGNOZ_ALERTMANAGER_LEGACY_API__URL", "http://localhost:9093/api")
	t.Setenv("SIGNOZ_ALERTMANAGER_SIGNOZ_ROUTE_REPEAT__INTERVAL", "5m")
	t.Setenv("SIGNOZ_ALERTMANAGER_SIGNOZ_EXTERNAL__URL", "https://example.com/test")
	t.Setenv("SIGNOZ_ALERTMANAGER_SIGNOZ_GLOBAL_RESOLVE__TIMEOUT", "10s")

	conf, err := config.New(
		context.Background(),
		config.ResolverConfig{
			Uris: []string{"env:"},
			ProviderFactories: []config.ProviderFactory{
				envprovider.NewFactory(),
			},
		},
		[]factory.ConfigFactory{
			NewConfigFactory(),
		},
	)
	require.NoError(t, err)

	actual := &Config{}
	err = conf.Unmarshal("alertmanager", actual, "yaml")
	require.NoError(t, err)

	def := NewConfigFactory().New().(Config)
	def.Signoz.Global.ResolveTimeout = model.Duration(10 * time.Second)
	def.Signoz.Route.RepeatInterval = 5 * time.Minute
	def.Signoz.ExternalURL = &url.URL{
		Scheme: "https",
		Host:   "example.com",
		Path:   "/test",
	}

	expected := &Config{
		Provider: "signoz",
		Signoz:   def.Signoz,
	}

	assert.Equal(t, expected, actual)
	assert.NoError(t, actual.Validate())
}

func TestAlertmanagerGlobalSMTPYAMLUnmarshal(t *testing.T) {
	yamlStr := `
alertmanager:
  signoz:
    global:
      resolve_timeout: 5m
      smtp_smarthost: "smtp.sendgrid.net:587"
      smtp_from: "alerts@example.com"
      smtp_hello: "otel.example.com"
      smtp_require_tls: true
      smtp_auth_username: "apikey"
      smtp_auth_password: ""
`
	var root map[string]any
	require.NoError(t, yamlv2.Unmarshal([]byte(yamlStr), &root))

	conf := config.NewConf()
	require.NoError(t, conf.Load(confmap.Provider(root, config.KoanfDelimiter), nil))

	actual := &Config{}
	require.NoError(t, conf.Unmarshal("alertmanager", actual, "yaml"))

	assert.Equal(t, "smtp.sendgrid.net", actual.Signoz.Global.SMTPSmarthost.Host)
	assert.Equal(t, "587", actual.Signoz.Global.SMTPSmarthost.Port)
	assert.Equal(t, "alerts@example.com", actual.Signoz.Global.SMTPFrom)
	assert.Equal(t, "otel.example.com", actual.Signoz.Global.SMTPHello)
	assert.True(t, actual.Signoz.Global.SMTPRequireTLS)
	assert.Equal(t, "apikey", actual.Signoz.Global.SMTPAuthUsername)
}
