# Cover image advice for copilot-pod

## Prompt

> Minimalist black-and-white studio product photo, wide 2:1 banner. A pod made of a matte black cylindrical base topped by a tall transparent glass dome, centered exactly in the frame, horizontally and vertically, with symmetrical empty dark space on both left and right. Proportions: the glass dome is two thirds of the pod's total height and the black base is one third. The pod stands on a dark glossy floor, softly lit from below with a white glow pooling evenly around its base. Inside the dome floats a luminous translucent glass sphere that looks friendly and cute: two round, wide-open, glowing eyes in vivid electric blue (#1F6FEB, GitHub blue) with a soft blue glow, and a small gentle smile, like a happy, curious little creature. Deep black background, even symmetrical rim light, high contrast, shallow depth of field, cinematic. The base has small white sans-serif text: "copilot-pod". No logos, no other text. Everything else strictly black, white and grey; the blue eyes are the only colour in the image.

## Free tools

- **Microsoft Designer / Bing Image Creator**: free with a Microsoft account; limited daily boosts.
- **Leonardo.ai**: free daily credits; free-tier images are public.
- **Ideogram**: free tier; good at rendering text such as "copilot-pod".
- **Stable Diffusion locally** (ComfyUI, Fooocus): fully free, needs a decent GPU.
- **Craiyon / Playground**: free, lower quality.

Check the tool's terms allow use in a public repo.

## Composition tips

- The tool may ignore "2:1". Pick a wide ratio in its settings, or generate square and crop.
- If the pod drifts off-center, add "front-on view, centered composition, symmetrical".
- Otherwise crop the result to center the pod.
- AI often garbles text: check that the label reads exactly "copilot-pod" and fix it in an editor if not.

## Friendly look and proportions

- Say "round, wide-open eyes" and "gentle smile"; closed or slanted eyes read as sleepy or angry.
- Add "cute, warm, approachable, soft rounded shapes" if the sphere still looks cold.
- Avoid "menacing", "intense" or "glowing red" wording.
- If the dome/base ratio is off, repeat "dome two thirds of total height, base one third" or crop and resize in an editor.

## Eye colour tips

- Name both the hex code and a colour word; models handle "electric blue" better than hex alone.
- If the blue looks washed out or turns white, add "saturated blue light, not white".
- If blue spills onto the pod or floor, add "no blue reflections on the glass or floor".
- For a blue-to-violet gradient (`#8534F3`), add "fading from blue to violet".
- Alternative: recolour in Photopea or GIMP. Select the eyes, then use Hue/Saturation with Colorize, or paint blue on a layer set to Color blend mode. This is more reliable than re-rolling.
- A blue colour is not a trademark problem; just avoid the actual Copilot logo shape.

## Using the result

Save as `copilot-pod/assets/cover.jpeg` (the README already links it).
