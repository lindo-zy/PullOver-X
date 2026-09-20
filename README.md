# PullOver X

Based on PullOver Pro by `c1d3rDev`.
Adapted for iOS 14+, added some features, and fixed some known issues.

## External Wake API (for tweak developers)

Other tweaks can wake the PullOver X handle/panel by posting the Darwin notification:

```
com.mlgm.pulloverx.external-wake
```

Behavior: when the handle is nubbed (shrunk), it expands (with the app rail). Nothing happens while the panel is open or the handle is already visible.

Any process can post it, e.g. from C/ObjC:

```objc
notify_post("com.mlgm.pulloverx.external-wake");
```

The feature can be toggled in settings ("External Wake"), and repeated notifications within one second are debounced.

## License

PullOver X is distributed under the [GNU General Public License v3.0](LICENSE).
