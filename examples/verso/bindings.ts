import { createZyncBaseReact } from "@zyncbase/client/react";
import type { ZyncBasePresence, ZyncBaseSchema } from "./schema-types";

export const {
	ZyncBaseProvider,
	useClient,
	useQuery,
	usePresence,
	useSyncStatus,
} = createZyncBaseReact<ZyncBaseSchema, never, ZyncBasePresence>();
