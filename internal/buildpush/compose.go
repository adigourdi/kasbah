package buildpush

import (
	"os"
	"sort"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/jv"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// Compose is the file the images to ship are derived from.
const Compose = "compose.prod.yml"

// Image is one built service: the image: compose names, which the build tags,
// and <base>:<version>, which is tagged, saved and loaded.
type Image struct{ Service, Source, Ref string }

// Base is image_base: the reference without its tag. A registry port is not a
// tag — only a colon in the last path component is.
func Base(ref string) string {
	last := ref[strings.LastIndex(ref, "/")+1:]
	if i := strings.LastIndex(last, ":"); i >= 0 {
		return ref[:len(ref)-len(last)+i]
	}
	return ref
}

// Built is every service of the compose document with a build: key, in jq's
// `keys` order. A built service must name its image: deploy moves
// <image>:current, and compose's generated name is not one it can move.
func Built(doc jv.Value, project, version string) ([]Image, error) {
	unreadable := cli.Fail("%s: could not read its services", Compose)
	var services jv.Value
	switch d := doc.(type) {
	case nil:
	case *jv.Map:
		services, _ = d.Get("services")
	default:
		return nil, unreadable
	}
	var svcs *jv.Map
	switch s := jv.Alt(services, jv.NewMap()).(type) {
	case *jv.Map:
		svcs = s
	default:
		return nil, unreadable
	}
	keys := svcs.Keys()
	sort.Strings(keys)

	var out []Image
	for _, name := range keys {
		v, _ := svcs.Get(name)
		svc, ok := v.(*jv.Map)
		if !ok {
			return nil, cli.Fail("%s: could not read service '%s'", Compose, name)
		}
		if !svc.Has("build") {
			continue
		}
		img, _ := svc.Get("image")
		image := strings.TrimSuffix(jv.Raw(jv.Alt(img, "")), "\r")
		if image == "" || image == "null" {
			return nil, cli.Fail("%s: service '%s' builds an image but does not name one", Compose, name).Cont(
				"kasbah tags what it builds <image>:<version>, and deploy moves",
				"<image>:current onto it — compose's own generated name is not one it can",
				"move. Give the service an image: key:",
				"    image: "+project+"-"+name+":current")
		}
		out = append(out, Image{Service: name, Source: image, Ref: Base(image) + ":" + version})
	}
	return out, nil
}

// ReadCompose loads the compose file in the current directory; why says, on
// a missing file, what the caller needed it for.
func ReadCompose(pwd, why string) (jv.Value, error) {
	if fi, err := os.Stat(Compose); err != nil || !fi.Mode().IsRegular() {
		return nil, cli.Fail("%s: not found (cwd=%s) — %s", Compose, pwd, why)
	}
	docs, err := yamlx.LoadFile(Compose)
	if err != nil {
		return nil, cli.Fail("%s: could not parse YAML", Compose).Cont(err.Error())
	}
	switch len(docs) {
	case 0:
		return nil, nil
	case 1:
		return docs[0], nil
	}
	return nil, cli.Fail("%s: expected a single YAML document", Compose)
}
