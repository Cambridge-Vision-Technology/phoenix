import {
  Flex,
  Heading,
  RichTooltip,
  Text,
  TooltipTrigger,
  TriggerWrap,
  View,
} from "@phoenix/components";
import type { Cell } from "@phoenix/legend/summary.generated.js";

export function PooledBenchmarkCell({ model }: { model: Cell }) {
  return (
    <TooltipTrigger>
      <TriggerWrap>
        <Flex direction="column" alignItems="end">
          <span
            className="font-mono"
            aria-label={`${model.label}: ${model.text}`}
          >
            {model.text}
          </span>
          <Text size="XS">{model.deltaText}</Text>
        </Flex>
      </TriggerWrap>
      <RichTooltip>
        <View width="size-3000">
          <Heading level={3}>{model.label}</Heading>
          <Flex direction="column" gap="size-50">
            <Text size="XS">{model.aggregation}</Text>
            <Text size="XS">{model.status}</Text>
            {model.details.map((field) => (
              <Flex
                key={field.label}
                justifyContent="space-between"
                gap="size-100"
              >
                <Text size="XS">{field.label}</Text>
                <Text size="XS">{field.value}</Text>
              </Flex>
            ))}
          </Flex>
        </View>
      </RichTooltip>
    </TooltipTrigger>
  );
}
