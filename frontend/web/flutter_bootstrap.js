{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    wasmAllowList: {
      blink: true,
      gecko: true,
      webkit: true,
      unknown: true,
    },
  },
});
