package test

import (
	"encoding/json"
	"os"
	"os/exec"
	"sort"
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/logger"
)

type KVContent struct {
	Secrets        map[string]string // name -> latest value
	Keys           []string
	Certificates   map[string]string // name -> latest version
	Tags           map[string]string
	AccessPolicies []string
}

func TestKeyVaultSync(t *testing.T) {
	sourceKV := os.Getenv("SOURCE_KEYVAULT_NAME")
	targetKV := os.Getenv("TARGET_KEYVAULT_NAME")

	if sourceKV == "" || targetKV == "" {
		t.Fatal("Source or Target Key Vault name not provided")
	}

	if !keyVaultExists(sourceKV) {
		t.Fatalf("Source Key Vault does not exist: %s", sourceKV)
	}
	if !keyVaultExists(targetKV) {
		t.Fatalf("Target Key Vault does not exist: %s", targetKV)
	}

	sourceContent := getKVFullContent(sourceKV)
	targetContent := getKVFullContent(targetKV)

	printKVContent("Source Vault", sourceContent, t)
	printKVContent("Target Vault", targetContent, t)

	failed := false

	// -------------------- Secrets --------------------
	for name, srcValue := range sourceContent.Secrets {
		if tgtValue, ok := targetContent.Secrets[name]; !ok {
			logger.Log(t, "Secret missing in target: %s", name)
			failed = true
		} else if srcValue != tgtValue {
			logger.Log(t, "Secret value mismatch: %s", name)
			failed = true
		}
	}
	for name := range targetContent.Secrets {
		if _, ok := sourceContent.Secrets[name]; !ok {
			logger.Log(t, "Extra secret in target not in source: %s", name)
			failed = true
		}
	}

	// -------------------- Keys --------------------
	if !stringSlicesEqual(sourceContent.Keys, targetContent.Keys) {
		logger.Log(t, "Keys mismatch: Source=%v Target=%v", sourceContent.Keys, targetContent.Keys)
		failed = true
	}

	// -------------------- Certificates --------------------
	for name, srcVersion := range sourceContent.Certificates {
		if tgtVersion, ok := targetContent.Certificates[name]; !ok {
			logger.Log(t, "Certificate missing in target: %s", name)
			failed = true
		} else if srcVersion != tgtVersion {
			logger.Log(t, "Certificate latest version mismatch: %s (source=%s target=%s)", name, srcVersion, tgtVersion)
			failed = true
		}
	}
	for name := range targetContent.Certificates {
		if _, ok := sourceContent.Certificates[name]; !ok {
			logger.Log(t, "Extra certificate in target not in source: %s", name)
			failed = true
		}
	}

	// -------------------- Tags --------------------
	if !stringMapsEqual(sourceContent.Tags, targetContent.Tags) {
		logger.Log(t, "Tags mismatch: Source=%v Target=%v", sourceContent.Tags, targetContent.Tags)
		failed = true
	}

	// -------------------- Access Policies --------------------
	if !stringSlicesEqual(sourceContent.AccessPolicies, targetContent.AccessPolicies) {
		logger.Log(t, "Access policies mismatch: Source=%v Target=%v", sourceContent.AccessPolicies, targetContent.AccessPolicies)
		failed = true
	}

	if failed {
		t.Fatalf("Key Vault comparison failed")
	}

	logger.Log(t, "Key Vault comparison successful")
}

// ======================= HELPERS =======================

func keyVaultExists(kvName string) bool {
	cmd := exec.Command("az", "keyvault", "show", "--name", kvName)
	return cmd.Run() == nil
}

func getKVFullContent(kvName string) KVContent {
	return KVContent{
		Secrets:        listKVSecrets(kvName),
		Keys:           listKVItems(kvName, "key"),
		Certificates:   listKVCertificates(kvName),
		Tags:           getKVTags(kvName),
		AccessPolicies: getKVAccessPolicyNames(kvName),
	}
}

// Fetch latest secret value
func listKVSecrets(kvName string) map[string]string {
	cmd := exec.Command("az", "keyvault", "secret", "list", "--vault-name", kvName, "-o", "json")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return map[string]string{}
	}
	var raw []map[string]interface{}
	_ = json.Unmarshal(out, &raw)
	secrets := map[string]string{}
	for _, obj := range raw {
		if name, ok := obj["name"].(string); ok {
			valCmd := exec.Command("az", "keyvault", "secret", "show", "--vault-name", kvName, "--name", name, "-o", "json")
			valOut, err := valCmd.CombinedOutput()
			if err == nil {
				var valObj map[string]interface{}
				_ = json.Unmarshal(valOut, &valObj)
				if v, ok := valObj["value"].(string); ok {
					secrets[name] = v
				}
			} else {
				secrets[name] = "<unable to fetch>"
			}
		}
	}
	return secrets
}

// List keys
func listKVItems(kvName string, itemType string) []string {
	cmd := exec.Command("az", "keyvault", itemType, "list", "--vault-name", kvName, "-o", "json")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return []string{}
	}
	var raw []map[string]interface{}
	_ = json.Unmarshal(out, &raw)
	items := []string{}
	for _, obj := range raw {
		if name, ok := obj["name"].(string); ok {
			items = append(items, strings.TrimSpace(name))
		}
	}
	sort.Strings(items)
	return items
}

// Fetch latest certificate version
func listKVCertificates(kvName string) map[string]string {
	cmd := exec.Command("az", "keyvault", "certificate", "list", "--vault-name", kvName, "-o", "json")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return map[string]string{}
	}
	var raw []map[string]interface{}
	_ = json.Unmarshal(out, &raw)
	certs := map[string]string{}
	for _, obj := range raw {
		if name, ok := obj["name"].(string); ok {
			verCmd := exec.Command("az", "keyvault", "certificate", "show", "--vault-name", kvName, "--name", name, "-o", "json")
			verOut, err := verCmd.CombinedOutput()
			if err == nil {
				var verObj map[string]interface{}
				_ = json.Unmarshal(verOut, &verObj)
				id := ""
				if v, ok := verObj["id"].(string); ok {
					parts := strings.Split(v, "/")
					if len(parts) > 0 {
						id = parts[len(parts)-1]
					}
				}
				certs[name] = id
			} else {
				certs[name] = "<unable to fetch>"
			}
		}
	}
	return certs
}

func getKVTags(kvName string) map[string]string {
	cmd := exec.Command("az", "keyvault", "show", "--name", kvName, "--query", "tags", "-o", "json")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return map[string]string{}
	}
	var tags map[string]string
	_ = json.Unmarshal(out, &tags)
	return tags
}

func getKVAccessPolicyNames(kvName string) []string {
	cmd := exec.Command("az", "keyvault", "show", "--name", kvName, "--query", "properties.accessPolicies[].objectId", "-o", "json")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return []string{}
	}
	var ids []string
	_ = json.Unmarshal(out, &ids)
	for i := range ids {
		ids[i] = strings.TrimSpace(ids[i])
	}
	sort.Strings(ids)
	return ids
}

// Helper functions
func stringSlicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	count := map[string]int{}
	for _, v := range a {
		count[v]++
	}
	for _, v := range b {
		if count[v] == 0 {
			return false
		}
		count[v]--
	}
	return true
}

func stringMapsEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if bv, ok := b[k]; !ok || bv != v {
			return false
		}
	}
	return true
}

func printKVContent(title string, content KVContent, t *testing.T) {
	logger.Log(t, "==== %s ====", title)

	logger.Log(t, "Secrets:")
	for k, v := range content.Secrets {
		logger.Log(t, "  %s: %s", k, v)
	}

	logger.Log(t, "Keys: %v", content.Keys)

	logger.Log(t, "Certificates (latest version):")
	for k, v := range content.Certificates {
		logger.Log(t, "  %s: %s", k, v)
	}

	logger.Log(t, "Tags: %v", content.Tags)
	logger.Log(t, "Access Policies: %v", content.AccessPolicies)
	logger.Log(t, "=========================")
}
